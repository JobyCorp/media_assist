defmodule MediaAssistWeb.SettingsLive.Index do
  @moduledoc """
  `/settings/index` — the media index: what gets cached from
  Radarr/Sonarr, how often, and whether new items are queued for
  embedding. "Sync now" enqueues `Media.SyncWorker` on the `:indexer`
  Oban queue.
  """

  use MediaAssistWeb, :live_view

  alias MediaAssist.Integrations
  alias MediaAssist.Media
  alias MediaAssistWeb.CompositeComponents
  alias MediaAssistWeb.SettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    settings = Integrations.get_index_settings()

    {:ok,
     assign(socket,
       page_title: "settings/index",
       settings: settings,
       stats: Media.stats(),
       form: to_form(Integrations.change_index_settings(settings))
     )}
  end

  @impl true
  def handle_event("validate", %{"index_settings" => params}, socket) do
    changeset = Integrations.change_index_settings(socket.assigns.settings, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"index_settings" => params}, socket) do
    case Integrations.update_index_settings(params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(
           settings: settings,
           form: to_form(Integrations.change_index_settings(settings))
         )
         |> put_flash(:info, "Index settings saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("sync_now", _params, socket) do
    case Oban.insert(MediaAssist.Media.SyncWorker.new(%{})) do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :info, "Sync queued on the indexer queue.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue sync: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_scope={@current_scope} active_nav="settings">
      <SettingsComponents.settings_shell active="index">
        <CompositeComponents.command_header command="settings index --edit">
          <:comment>
            cached titles become the vector graph the assistant and recommender read
          </:comment>
        </CompositeComponents.command_header>

        <dl class="grid max-w-md grid-cols-3 gap-px border border-base-content/10 bg-base-content/10 text-center text-sm">
          <div class="bg-base-200 px-3 py-2.5">
            <dt class="text-xs text-base-content/50">movies</dt>
            <dd class="font-medium">{@stats.movies}</dd>
          </div>
          <div class="bg-base-200 px-3 py-2.5">
            <dt class="text-xs text-base-content/50">series</dt>
            <dd class="font-medium">{@stats.series}</dd>
          </div>
          <div class="bg-base-200 px-3 py-2.5">
            <dt class="text-xs text-base-content/50">embedded</dt>
            <dd class="font-medium">{@stats.embedded}</dd>
          </div>
        </dl>
        <p class="text-xs text-base-content/40">
          last sync:
          <span :if={@settings.last_synced_at}>
            {Calendar.strftime(@settings.last_synced_at, "%Y-%m-%d %H:%M UTC")}
          </span>
          <span :if={!@settings.last_synced_at}>never</span>
        </p>

        <.form
          for={@form}
          id="index-form"
          phx-change="validate"
          phx-submit="save"
          class="max-w-md space-y-4"
        >
          <.input field={@form[:sync_movies]} type="checkbox" label="Cache movies from Radarr" />
          <.input field={@form[:sync_series]} type="checkbox" label="Cache series from Sonarr" />
          <.input
            field={@form[:embed_on_sync]}
            type="checkbox"
            label="Embed new items through the AI gateway"
          />
          <.input
            field={@form[:sync_interval_minutes]}
            type="select"
            label="Sync interval"
            options={[
              {"hourly", 60},
              {"every 3 hours", 180},
              {"every 6 hours", 360},
              {"every 12 hours", 720},
              {"daily", 1440}
            ]}
          />
          <div class="pt-2">
            <.button variant="primary" phx-disable-with="Saving…">Save index settings</.button>
          </div>
        </.form>
        <div class="max-w-md">
          <.button phx-click="sync_now" phx-disable-with="Queuing…">Sync now</.button>
        </div>
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end
end
