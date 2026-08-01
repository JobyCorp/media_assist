defmodule MediaAssistWeb.LibraryLive do
  @moduledoc """
  `/library` — the browsable media index: everything cached from
  Radarr/Sonarr, searchable and filterable. Filters live in the URL
  (`push_patch`), so views are shareable and back-button friendly; the
  command header always shows the "command" that produced the grid.
  """

  use MediaAssistWeb, :live_view

  alias MediaAssist.Media
  alias MediaAssistWeb.CompositeComponents
  alias MediaAssistWeb.MediaComponents

  @impl true
  def mount(_params, _session, socket) do
    stats = Media.stats()

    {:ok,
     assign(socket,
       page_title: "library",
       genres: Media.genres(),
       total_titles: stats.movies + stats.series
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      "q" => params["q"] || "",
      "kind" => params["kind"] || "",
      "genre" => params["genre"] || "",
      "presence" => params["presence"] || ""
    }

    page = parse_page(params["page"])

    result =
      Media.search_items(
        q: filters["q"],
        kind: filters["kind"],
        genre: filters["genre"],
        presence: filters["presence"],
        page: page
      )

    {:noreply,
     assign(socket,
       filters: filters,
       form: to_form(filters, as: :filter),
       result: result
     )}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter_params}, socket) do
    {:noreply, push_patch(socket, to: library_path(filter_params, 1))}
  end

  defp library_path(filters, page) do
    query =
      %{
        "q" => filters["q"],
        "kind" => filters["kind"],
        "genre" => filters["genre"],
        "presence" => filters["presence"],
        "page" => page
      }
      |> Enum.reject(fn {key, value} -> value in ["", nil] or (key == "page" and value == 1) end)
      |> Map.new()

    ~p"/library?#{query}"
  end

  defp parse_page(nil), do: 1

  defp parse_page(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _other -> 1
    end
  end

  # The grid's provenance, as the command that would produce it.
  defp command(filters) do
    flags =
      [
        presence_flag(filters["presence"]),
        filters["kind"] != "" && "--kind #{filters["kind"]}",
        filters["genre"] != "" && ~s(--genre "#{filters["genre"]}"),
        filters["q"] != "" && ~s(--grep "#{filters["q"]}")
      ]
      |> Enum.filter(& &1)

    case flags do
      [] -> "library --held"
      _some -> "library " <> Enum.join(flags, " ")
    end
  end

  defp presence_flag(presence) when presence in ["", "held"], do: nil
  defp presence_flag("all"), do: "--all"
  defp presence_flag(status), do: "--" <> String.replace(status, "_", "-")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_scope={@current_scope} active_nav="library">
      <main class="mx-auto w-full max-w-[1600px] space-y-6 px-4 py-8 sm:px-6">
        <header class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
          <h1 class="text-lg font-semibold">~/library</h1>
          <p class="text-xs text-base-content/40">
            {@result.total} of {@total_titles} titles
          </p>
        </header>

        <CompositeComponents.command_header command={command(@filters)}>
          <:comment>
            cached from the arrstack — filters patch the URL, so views are shareable
          </:comment>
        </CompositeComponents.command_header>

        <.form
          for={@form}
          id="library-filter"
          phx-change="filter"
          class="flex flex-wrap items-end gap-4"
        >
          <div class="w-full max-w-xs">
            <.input
              field={@form[:q]}
              type="text"
              label="grep"
              placeholder="title…"
              phx-debounce="300"
              spellcheck="false"
              autocomplete="off"
            />
          </div>
          <div class="w-36">
            <.input
              field={@form[:kind]}
              type="select"
              label="kind"
              options={[{"all", ""}, {"movies", "movie"}, {"series", "series"}]}
            />
          </div>
          <div class="w-48">
            <.input
              field={@form[:genre]}
              type="select"
              label="genre"
              options={[{"all", ""} | Enum.map(@genres, &{&1, &1})]}
            />
          </div>
          <div class="w-44">
            <.input
              field={@form[:presence]}
              type="select"
              label="presence"
              options={[
                {"held", ""},
                {"everything", "all"},
                {"in library", "in_library"},
                {"departed", "departed"},
                {"seen, not held", "known"}
              ]}
            />
          </div>
        </.form>

        <CompositeComponents.empty_state
          :if={@result.items == []}
          icon="hero-film"
          title="No matches"
        >
          Nothing in the index matches these filters. Loosen them, or run a sync
          from the index settings.
        </CompositeComponents.empty_state>

        <div
          :if={@result.items != []}
          class="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 2xl:grid-cols-8"
        >
          <MediaComponents.media_card
            :for={item <- @result.items}
            title={item.title}
            year={item.year}
            kind={item.kind}
            status={item.status}
            poster_url={item.poster_url}
            rt={item.ratings["rt"]}
            navigate={~p"/library/#{item.id}"}
          />
        </div>

        <nav
          :if={@result.pages > 1}
          class="flex items-center justify-center gap-4 pt-2 text-sm"
          aria-label="Pagination"
        >
          <.link
            :if={@result.page > 1}
            patch={library_path(@filters, @result.page - 1)}
            class="text-base-content/60 hover:text-base-content"
          >
            ‹ prev
          </.link>
          <span class="text-xs text-base-content/40">
            page {@result.page}/{@result.pages}
          </span>
          <.link
            :if={@result.page < @result.pages}
            patch={library_path(@filters, @result.page + 1)}
            class="text-base-content/60 hover:text-base-content"
          >
            next ›
          </.link>
        </nav>
      </main>
    </Layouts.app>
    """
  end
end
