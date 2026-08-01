defmodule MediaAssistWeb.HomeLive do
  @moduledoc """
  The feed: real recommendations from the vector graph (embedding
  neighbors of the user's recent watches), recently added titles from
  the arrstack, and the household's watch log. Every card links into
  `~/library`.
  """

  use MediaAssistWeb, :live_view

  alias MediaAssist.Media
  alias MediaAssist.Media.Recommender
  alias MediaAssistWeb.CompositeComponents
  alias MediaAssistWeb.MediaComponents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    {:ok,
     assign(socket,
       page_title: "feed",
       user: user,
       stats: Media.stats(),
       watch_stats: Media.watch_stats(),
       recommended: Recommender.for_user(user),
       recently_added: Media.recently_added(8),
       recent_watches: Media.recent_watches(8)
     )}
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp handle(nil), do: "guest"
  defp handle(user), do: user.email |> String.split("@") |> hd()

  defp watcher_name(user), do: user.emby_user_name || handle(user)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_scope={@current_scope} active_nav="feed">
      <main class="mx-auto w-full max-w-[1600px] space-y-10 px-4 py-8 sm:px-6">
        <header class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
          <h1 class="text-lg font-semibold">~/feed</h1>
          <p class="text-xs text-base-content/40">
            movies:<span class="text-base-content/70">{@stats.movies}</span>
            series:<span class="text-base-content/70">{@stats.series}</span>
            embedded:<span class="text-base-content/70">{@stats.embedded}</span>
            watches:<span class="text-base-content/70">{@watch_stats.watches}</span>
          </p>
        </header>

        <section class="space-y-4">
          <CompositeComponents.command_header command={"recommend --user #{handle(@user)} --limit 8"}>
            <:comment :if={@recommended.source == :watches}>
              embedding neighbors of your recent watches, minus what you've seen
            </:comment>
            <:comment :if={@recommended.source == :recently_added && @user}>
              no watch history yet — map your account to an emby user in settings/connections
            </:comment>
            <:comment :if={!@user}>
              log in for personal recommendations — showing new arrivals
            </:comment>
          </CompositeComponents.command_header>
          <CompositeComponents.empty_state
            :if={@recommended.recommendations == []}
            icon="hero-sparkles"
            title="Nothing to recommend yet"
          >
            Sync the library and embed it from the index settings, then watch
            something — the feed builds itself from there.
          </CompositeComponents.empty_state>
          <div
            :if={@recommended.recommendations != []}
            class="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 2xl:grid-cols-8"
          >
            <MediaComponents.media_card
              :for={rec <- @recommended.recommendations}
              title={rec.item.title}
              year={rec.item.year}
              kind={rec.item.kind}
              status={rec.item.status}
              poster_url={rec.item.poster_url}
              score={rec.match}
              rt={rec.item.ratings["rt"]}
              note={rec.reason}
              navigate={~p"/library/#{rec.item.id}"}
            />
          </div>
        </section>

        <section class="space-y-4">
          <CompositeComponents.command_header command="library --added --recent">
            <:comment>newest arrivals, straight from radarr and sonarr</:comment>
          </CompositeComponents.command_header>
          <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 2xl:grid-cols-8">
            <MediaComponents.media_card
              :for={item <- @recently_added}
              title={item.title}
              year={item.year}
              kind={item.kind}
              status={item.status}
              poster_url={item.poster_url}
              note={item.added_at && "added " <> Calendar.strftime(item.added_at, "%Y-%m-%d")}
              navigate={~p"/library/#{item.id}"}
            />
          </div>
        </section>

        <section class="space-y-4">
          <CompositeComponents.command_header command="watch-log --all-users --recent" tone="accent">
            <:comment>what the household has been watching, via emby</:comment>
          </CompositeComponents.command_header>
          <CompositeComponents.empty_state
            :if={@recent_watches == []}
            icon="hero-play"
            title="No watch history yet"
          >
            Map accounts to Emby users in settings/connections and the log fills in
            on the next sync.
          </CompositeComponents.empty_state>
          <ul
            :if={@recent_watches != []}
            class="divide-y divide-base-content/10 border border-base-content/10 bg-base-200 text-sm"
          >
            <li
              :for={{watch, item, user} <- @recent_watches}
              class="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-2.5"
            >
              <.link
                navigate={~p"/library/#{item.id}"}
                class="min-w-0 flex-1 truncate font-medium hover:text-primary"
              >
                {item.title}
              </.link>
              <span class="text-xs text-base-content/50">
                by <span class="text-accent">{watcher_name(user)}</span>
              </span>
              <span :if={watch.play_count > 1} class="text-xs text-base-content/50">
                ×{watch.play_count}
              </span>
              <span class="text-xs text-base-content/40">
                {Calendar.strftime(watch.last_played_at, "%Y-%m-%d")}
              </span>
            </li>
          </ul>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
