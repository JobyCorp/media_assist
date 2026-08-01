defmodule MediaAssistWeb.DiscoverLive do
  @moduledoc """
  `/discover` — finding titles beyond the library.

  The default view is instant browse: shelves (new releases, trending,
  what's hot, because-of-your-library) from Radarr's Discover feed — one
  arr call, no LLM. Deep search stays behind an explicit query (`?q=`)
  or a library seed (`?like=<item_id>`), which run the slower LLM +
  lookup + embedding pipeline.

  Every candidate carries a request button that creates a `Requests` row
  and pushes to the arr.
  """

  use MediaAssistWeb, :live_view

  alias MediaAssist.Discovery
  alias MediaAssist.Media
  alias MediaAssist.Requests
  alias MediaAssistWeb.CompositeComponents
  alias MediaAssistWeb.MediaComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "discover", requested: %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    seed = params["like"] && seed_item(params["like"])
    query = params["q"] || ""
    kind = if params["kind"] in ~w(movie series), do: params["kind"], else: "movie"
    tab = if params["tab"] == "tv", do: "series", else: "movie"

    socket =
      assign(socket,
        seed: seed,
        query: query,
        kind: kind,
        tab: tab,
        mode: if(seed || query != "", do: :search, else: :browse),
        form: to_form(%{"q" => query, "kind" => kind}, as: :discover),
        candidates: nil,
        shelves: nil,
        state: :idle
      )

    {:noreply, start_work(socket)}
  end

  @impl true
  def handle_event("search", %{"discover" => %{"q" => q, "kind" => kind}}, socket) do
    q = String.trim(q)

    if q == "" do
      {:noreply, push_patch(socket, to: ~p"/discover")}
    else
      {:noreply, push_patch(socket, to: ~p"/discover?#{%{q: q, kind: kind}}")}
    end
  end

  def handle_event("request", %{"kind" => kind, "id" => id}, socket) do
    candidate = find_candidate(socket.assigns, kind, String.to_integer(id))
    candidate = candidate && ensure_tvdb(candidate)
    user = socket.assigns.current_scope.user

    if candidate == :unresolvable do
      {:noreply,
       put_flash(socket, :error, "Sonarr couldn't resolve that title — try deep search.")}
    else
      request_candidate(socket, user, candidate)
    end
  end

  defp request_candidate(socket, user, candidate) do
    case candidate &&
           Requests.create_request(user, %{
             kind: candidate.kind,
             title: candidate.title,
             year: candidate.year,
             tmdb_id: candidate.tmdb_id,
             tvdb_id: candidate.tvdb_id,
             poster_url: candidate.poster_url
           }) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> update(:requested, &Map.put(&1, candidate_key(candidate), true))
         |> put_flash(
           :info,
           "#{candidate.title} requested — adding to #{arr_name(candidate.kind)}."
         )}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> update(:requested, &Map.put(&1, candidate_key(candidate), true))
         |> put_flash(:info, "#{candidate.title} was already requested.")}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:discover, {:ok, result}, socket) do
    case result do
      {:ok, %{candidates: candidates}} ->
        {:noreply, assign(socket, candidates: candidates, state: :done)}

      {:ok, %{} = shelves} ->
        {:noreply, assign(socket, shelves: shelves, state: :done)}

      {:error, reason} ->
        {:noreply, assign(socket, candidates: [], state: {:error, to_string(reason)})}
    end
  end

  def handle_async(:discover, {:exit, reason}, socket) do
    {:noreply, assign(socket, candidates: [], state: {:error, inspect(reason)})}
  end

  # Shelf TV candidates carry only a tmdb id; requests need tvdb.
  defp ensure_tvdb(%{kind: "series", tvdb_id: nil} = candidate) do
    case Discovery.resolve_tvdb(candidate) do
      {:ok, tvdb_id} -> %{candidate | tvdb_id: tvdb_id}
      :error -> :unresolvable
    end
  end

  defp ensure_tvdb(candidate), do: candidate

  defp start_work(socket) do
    %{seed: seed, query: query, kind: kind, mode: mode, tab: tab} = socket.assigns

    cond do
      !connected?(socket) ->
        socket

      mode == :browse ->
        assign(socket, state: :searching)
        |> start_async(:discover, fn -> Discovery.browse(tab) end)

      seed ->
        assign(socket, state: :searching)
        |> start_async(:discover, fn -> Discovery.discover(seed) end)

      true ->
        assign(socket, state: :searching)
        |> start_async(:discover, fn -> Discovery.discover(query, kind: kind) end)
    end
  end

  defp seed_item(id) do
    case Media.fetch_item(id) do
      {:ok, item} -> item
      :error -> nil
    end
  end

  defp find_candidate(assigns, kind, provider_id) do
    ((assigns.candidates || []) ++
       Enum.flat_map(assigns.shelves || %{}, fn {_name, list} -> list end))
    |> Enum.find(fn candidate ->
      candidate.kind == kind and provider_value(candidate) == provider_id
    end)
  end

  defp provider_value(%{kind: "movie"} = candidate), do: candidate.tmdb_id
  # Shelf TV candidates have no tvdb id yet; tmdb id identifies them.
  defp provider_value(%{kind: "series"} = candidate), do: candidate.tvdb_id || candidate.tmdb_id

  # Stable across tvdb resolution (which fills tvdb_id after request).
  defp candidate_key(candidate), do: {candidate.kind, candidate.tmdb_id || candidate.tvdb_id}

  defp arr_name("movie"), do: "radarr"
  defp arr_name("series"), do: "sonarr"

  defp command(%{mode: :browse, tab: "series"}), do: "discover --browse --tv"
  defp command(%{mode: :browse}), do: "discover --browse"
  defp command(%{seed: %{title: title}}) when title != nil, do: ~s(discover --like "#{title}")

  defp command(%{query: query, kind: kind}) when query != "",
    do: ~s(discover --kind #{kind} --grep "#{query}")

  defp command(_assigns), do: "discover"

  defp comment(:searching, :browse), do: "pulling radarr's discover feed…"

  defp comment(:searching, :search),
    do: "deep search — the model proposes, the arrs resolve; a few seconds"

  defp comment(:done, :browse), do: "filtered to titles not in the library"

  defp comment(:done, :search),
    do: "resolved via the arrs, deduped against the library, ranked by embedding match"

  defp comment({:error, reason}, _mode), do: "discovery failed: #{reason}"
  defp comment(:idle, _mode), do: "browse below, or run a deep search"

  # trending/watched come from trakt when connected; popular is the
  # tmdb-buzz fallback shelf when it isn't. Absent keys don't render.
  @movie_shelves [
    {:new_releases, "discover --new-releases", "recently released, not in the library"},
    {:trending, "discover --trending", "being watched right now"},
    {:watched, "discover --most-watched", "most watched this week"},
    {:popular, "discover --popular", "what's hot on tmdb right now"},
    {:recommended, "discover --recommended", "picked by radarr from the shape of this library"}
  ]

  # Covers both TV sources — trakt fills trending/watched/popular, tmdb
  # fills airing/trending/popular; absent keys simply don't render.
  @tv_shelves [
    {:trending, "discover --tv --trending", "being watched right now"},
    {:watched, "discover --tv --most-watched", "most watched this week"},
    {:airing, "discover --tv --airing-now", "currently on the air"},
    {:popular, "discover --tv --popular", "long-run popularity"}
  ]

  defp shelf_defs("series"), do: @tv_shelves
  defp shelf_defs(_movie), do: @movie_shelves

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_scope={@current_scope} active_nav="discover">
      <main class="mx-auto w-full max-w-[1600px] space-y-10 px-4 py-8 sm:px-6">
        <header class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
          <h1 class="text-lg font-semibold">~/discover</h1>
          <p :if={@seed} class="text-xs text-base-content/40">
            seeded from
            <.link navigate={~p"/library/#{@seed.id}"} class="text-primary/80 hover:text-primary">
              {@seed.title}
            </.link>
          </p>
        </header>

        <div class="space-y-4">
          <CompositeComponents.command_header command={command(assigns)} tone="accent">
            <:comment>{comment(@state, @mode)}</:comment>
          </CompositeComponents.command_header>

          <.form
            for={@form}
            id="discover-form"
            phx-submit="search"
            class="flex flex-wrap items-end gap-4"
          >
            <div class="w-full max-w-md">
              <.input
                field={@form[:q]}
                type="text"
                label="deep search"
                placeholder="mind-bending sci-fi like Blade Runner…"
                spellcheck="false"
                autocomplete="off"
              />
            </div>
            <div class="w-36">
              <.input
                field={@form[:kind]}
                type="select"
                label="kind"
                options={[{"movies", "movie"}, {"series", "series"}]}
              />
            </div>
            <%!-- mb-3 offsets the input wrapper's below-field space (fieldset
                 padding + mb-2) so items-end lines up with the field bottoms --%>
            <.button variant="primary" class="mb-3" phx-disable-with="Searching…">Search</.button>
            <.link
              :if={@mode == :search}
              patch={~p"/discover"}
              class="mb-3 pb-2 text-xs text-base-content/50 hover:text-base-content"
            >
              ‹ back to browse
            </.link>
          </.form>
        </div>

        <p :if={@state == :searching} class="text-sm text-base-content/40">
          <span class="cursor-blink">▮</span> {if @mode == :browse,
            do: "loading shelves…",
            else: "generating and resolving candidates…"}
        </p>

        <%!-- Browse tabs --%>
        <div :if={@mode == :browse} class="flex gap-4 text-sm">
          <.link
            patch={~p"/discover"}
            class={[
              @tab == "movie" && "text-primary",
              @tab != "movie" && "text-base-content/50 hover:text-base-content"
            ]}
          >
            movies{if @tab == "movie", do: "*"}
          </.link>
          <.link
            patch={~p"/discover?tab=tv"}
            class={[
              @tab == "series" && "text-primary",
              @tab != "series" && "text-base-content/50 hover:text-base-content"
            ]}
          >
            tv{if @tab == "series", do: "*"}
          </.link>
        </div>

        <%!-- Browse shelves --%>
        <section
          :for={{key, cmd, note} <- shelf_defs(@tab)}
          :if={@mode == :browse && @shelves}
          class="space-y-4"
        >
          <CompositeComponents.command_header :if={@shelves[key] not in [nil, []]} command={cmd}>
            <:comment>{note}</:comment>
          </CompositeComponents.command_header>
          <div
            :if={@shelves[key] not in [nil, []]}
            class="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6"
          >
            <.candidate_card
              :for={candidate <- @shelves[key]}
              candidate={candidate}
              requested={@requested[candidate_key(candidate)]}
            />
          </div>
        </section>

        <%!-- Deep search results --%>
        <CompositeComponents.empty_state
          :if={@mode == :search && @state == :done && @candidates == []}
          icon="hero-sparkles"
          title="Nothing new found"
        >
          Every candidate resolved to something already in the library. Try a more
          specific ask.
        </CompositeComponents.empty_state>

        <div
          :if={@mode == :search && @candidates not in [nil, []]}
          class="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 2xl:grid-cols-8"
        >
          <.candidate_card
            :for={candidate <- @candidates}
            candidate={candidate}
            requested={@requested[candidate_key(candidate)]}
          />
        </div>
      </main>
    </Layouts.app>
    """
  end

  attr :candidate, :map, required: true
  attr :requested, :boolean, default: false

  defp candidate_card(assigns) do
    ~H"""
    <MediaComponents.media_card
      title={@candidate.title}
      year={@candidate.year}
      kind={@candidate.kind}
      status={nil}
      poster_url={@candidate.poster_url}
      score={@candidate.match}
      rt={@candidate.rt}
      note={@candidate.match && "via " <> Enum.join(@candidate.sources, "+")}
    >
      <:action>
        <.button
          :if={!@requested}
          size="sm"
          phx-click="request"
          phx-value-kind={@candidate.kind}
          phx-value-id={provider_value(@candidate)}
          phx-disable-with="…"
        >
          + request
        </.button>
        <span :if={@requested} class="text-xs text-accent">◌ requested</span>
      </:action>
    </MediaComponents.media_card>
    """
  end
end
