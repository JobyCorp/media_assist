defmodule MediaAssistWeb.LibraryItemLive do
  @moduledoc """
  `/library/:id` — one title from the index: poster, metadata as
  `key: value` readout, overview, and two related-media sections that
  come alive as the graph fills in — embedding similarity and explicit
  graph edges. Both degrade to honest `#` comments while empty.
  """

  use MediaAssistWeb, :live_view

  alias MediaAssist.Media
  alias MediaAssist.Requests
  alias MediaAssistWeb.CompositeComponents
  alias MediaAssistWeb.MediaComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Media.fetch_item(id) do
      {:ok, item} ->
        {:ok,
         assign(socket,
           page_title: item.title,
           item: item,
           similar: Media.similar_items(item, limit: 8),
           neighbors: Media.neighbors(item, limit: 8),
           watchers: Media.item_watchers(item),
           requested: requestable?(item) && Requests.existing_for_item?(item)
         )}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "That title is not in the index.")
         |> push_navigate(to: ~p"/library")}
    end
  end

  @impl true
  def handle_event("request", _params, socket) do
    %{item: item, current_scope: scope} = socket.assigns

    case scope && scope.user &&
           Requests.create_request(scope.user, %{
             kind: item.kind,
             title: item.title,
             year: item.year,
             tmdb_id: item.tmdb_id,
             tvdb_id: item.tvdb_id,
             poster_url: item.poster_url
           }) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> assign(:requested, true)
         |> put_flash(:info, "#{item.title} requested — it'll come home on the next grab.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:requested, true)
         |> put_flash(:info, "#{item.title} was already requested.")}

      nil ->
        {:noreply, put_flash(socket, :error, "Log in to request titles.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Re-acquirable: seen-not-held or deleted, with the provider id the
  # arr needs for an add.
  defp requestable?(%{status: status} = item) when status in ["known", "departed"] do
    (item.kind == "movie" and item.tmdb_id != nil) or
      (item.kind == "series" and item.tvdb_id != nil)
  end

  defp requestable?(_item), do: false

  defp id_row(item) do
    [
      item.tmdb_id && "tmdb:#{item.tmdb_id}",
      item.tvdb_id && "tvdb:#{item.tvdb_id}",
      item.imdb_id && "imdb:#{item.imdb_id}",
      item.service_item_id && "#{item.service}:#{item.service_item_id}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("  ")
  end

  defp watcher_handle(user), do: user.emby_user_name || user.email |> String.split("@") |> hd()

  @ratings_order ~w(rt metacritic imdb tmdb trakt community)

  defp ratings_row(ratings) do
    @ratings_order
    |> Enum.filter(&Map.has_key?(ratings, &1))
    |> Enum.map_join("  ", fn key -> "#{key}:#{format_rating(ratings[key])}" end)
  end

  defp format_rating(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_rating(value), do: to_string(value)

  defp status_text("in_library"), do: "✓ in library"
  defp status_text("requested"), do: "◌ requested"
  defp status_text("missing"), do: "+ not in library"
  defp status_text("departed"), do: "− departed"
  defp status_text("known"), do: "○ seen, not held"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_scope={@current_scope} active_nav="library">
      <main class="mx-auto w-full max-w-5xl space-y-10 px-4 py-8 sm:px-6">
        <header class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
          <h1 class="text-lg font-semibold">
            <.link navigate={~p"/library"} class="text-base-content/50 hover:text-base-content">
              ~/library
            </.link>
            <span class="text-base-content/40">/</span> {@item.title}
          </h1>
          <.link navigate={~p"/library"} class="text-xs text-base-content/50 hover:text-base-content">
            ‹ back
          </.link>
        </header>

        <section class="space-y-4">
          <CompositeComponents.command_header command={~s(library show "#{@item.title}")}>
            <:comment>
              synced from {@item.service}{if @item.synced_at,
                do: " · " <> Calendar.strftime(@item.synced_at, "%Y-%m-%d %H:%M UTC")}
            </:comment>
            <:actions :if={requestable?(@item) && @current_scope}>
              <.button :if={!@requested} size="sm" phx-click="request" phx-disable-with="…">
                + request
              </.button>
              <span :if={@requested} class="text-xs text-accent">◌ requested</span>
            </:actions>
          </CompositeComponents.command_header>

          <div class="flex flex-col gap-6 sm:flex-row">
            <div class="w-48 shrink-0 sm:w-56">
              <div class="overflow-hidden border border-base-content/10 bg-base-200">
                <img
                  :if={@item.poster_url}
                  src={@item.poster_url}
                  alt={"Poster for #{@item.title}"}
                  class="aspect-[2/3] w-full object-cover"
                />
                <div
                  :if={!@item.poster_url}
                  class="flex aspect-[2/3] w-full items-center justify-center text-6xl font-bold text-base-content/25"
                  aria-hidden="true"
                >
                  {String.first(@item.title)}
                </div>
              </div>
            </div>

            <div class="min-w-0 flex-1 space-y-4 text-sm">
              <div class="space-y-1">
                <h2 class="text-xl font-semibold">
                  {@item.title}
                  <span :if={@item.year} class="font-normal text-base-content/50">({@item.year})</span>
                </h2>
                <p class="text-xs text-base-content/50">{@item.kind}</p>
              </div>

              <dl class="space-y-1 text-xs">
                <div class="flex gap-2">
                  <dt class="w-16 shrink-0 text-base-content/40">status:</dt>
                  <dd class={[
                    @item.status == "in_library" && "text-primary",
                    @item.status == "requested" && "text-accent",
                    @item.status in ["missing", "departed", "known"] && "text-base-content/60"
                  ]}>
                    {status_text(@item.status)}<span
                      :if={@item.status == "departed" && @item.departed_at}
                      class="text-base-content/40"
                    > · last held {Calendar.strftime(@item.departed_at, "%Y-%m-%d")}</span>
                  </dd>
                </div>
                <div :if={@item.genres != []} class="flex gap-2">
                  <dt class="w-16 shrink-0 text-base-content/40">genres:</dt>
                  <dd class="text-base-content/75">{Enum.join(@item.genres, " · ")}</dd>
                </div>
                <div class="flex gap-2">
                  <dt class="w-16 shrink-0 text-base-content/40">ids:</dt>
                  <dd class="text-base-content/60">{id_row(@item)}</dd>
                </div>
                <div :if={@item.ratings != %{}} class="flex gap-2">
                  <dt class="w-16 shrink-0 text-base-content/40">ratings:</dt>
                  <dd class="text-base-content/60">{ratings_row(@item.ratings)}</dd>
                </div>
                <div class="flex gap-2">
                  <dt class="w-16 shrink-0 text-base-content/40">vector:</dt>
                  <dd class="text-base-content/60">
                    {if @item.embedding, do: "embedded", else: "not embedded yet"}
                  </dd>
                </div>
                <div class="flex gap-2">
                  <dt class="w-16 shrink-0 text-base-content/40">watched:</dt>
                  <dd :if={@watchers == []} class="text-base-content/40">nobody yet</dd>
                  <dd :if={@watchers != []} class="text-base-content/75">
                    <span :for={{watch, user} <- @watchers} class="mr-3">
                      <span class="text-accent">{watcher_handle(user)}</span><span
                        :if={watch.play_count > 1}
                        class="text-base-content/50"
                      > ×{watch.play_count}</span><span
                        :if={watch.favorite}
                        class="text-error/80"
                      > ♥</span><span :if={watch.rating} class="text-base-content/60">
                        {watch.rating}/10</span><span :if={watch.liked == false} class="text-base-content/50">
                        ↓
                      </span><span
                        :if={watch.last_played_at}
                        class="text-base-content/40"
                      > · {Calendar.strftime(watch.last_played_at, "%Y-%m-%d")}</span>
                    </span>
                  </dd>
                </div>
              </dl>

              <p :if={@item.overview} class="max-w-2xl leading-relaxed text-base-content/75">
                {@item.overview}
              </p>
            </div>
          </div>
        </section>

        <section class="space-y-4">
          <CompositeComponents.command_header command={
            ~s(similar --to "#{@item.title}" --via embedding)
          }>
            <:comment :if={@similar == []}>
              {if @item.embedding,
                do: "no other embedded titles to compare against yet",
                else: "this title has no embedding yet — enable embed-on-sync in settings/index"}
            </:comment>
            <:comment :if={@similar != []}>nearest by cosine distance in the index</:comment>
            <:actions>
              <.button size="sm" navigate={~p"/discover?like=#{@item.id}"}>
                discover beyond the library →
              </.button>
            </:actions>
          </CompositeComponents.command_header>
          <div
            :if={@similar != []}
            class="grid grid-cols-2 gap-3 sm:grid-cols-4 lg:grid-cols-6"
          >
            <MediaComponents.media_card
              :for={similar_item <- @similar}
              title={similar_item.title}
              year={similar_item.year}
              kind={similar_item.kind}
              status={similar_item.status}
              poster_url={similar_item.poster_url}
              navigate={~p"/library/#{similar_item.id}"}
            />
          </div>
        </section>

        <section class="space-y-4">
          <CompositeComponents.command_header command={~s(graph neighbors --of "#{@item.title}")}>
            <:comment :if={@neighbors == []}>
              no edges yet — the graph builds as watch history and embeddings land
            </:comment>
            <:comment :if={@neighbors != []}>explicit relationships, heaviest first</:comment>
          </CompositeComponents.command_header>
          <div
            :if={@neighbors != []}
            class="grid grid-cols-2 gap-3 sm:grid-cols-4 lg:grid-cols-6"
          >
            <MediaComponents.media_card
              :for={{edge, neighbor} <- @neighbors}
              title={neighbor.title}
              year={neighbor.year}
              kind={neighbor.kind}
              status={neighbor.status}
              poster_url={neighbor.poster_url}
              note={"#{edge.relation} · w #{edge.weight}"}
              navigate={~p"/library/#{neighbor.id}"}
            />
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
