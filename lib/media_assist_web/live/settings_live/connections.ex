defmodule MediaAssistWeb.SettingsLive.Connections do
  @moduledoc """
  `/settings/connections` — the backend services the app talks to.
  Lists saved connections with per-row ping/delete, plus a form to add a
  new Radarr / Sonarr / SABnzbd / Emby connection.

  When an Emby connection exists, the page also maps app accounts to
  Emby users (the source of per-user watch history). Emby's user list is
  fetched async, like the gateway model catalog.
  """

  use MediaAssistWeb, :live_view

  alias MediaAssist.Accounts
  alias MediaAssist.Integrations
  alias MediaAssist.Integrations.Connection
  alias MediaAssistWeb.CompositeComponents
  alias MediaAssistWeb.SettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "settings/connections", emby_users: nil, emby_users_state: :loading)
     |> assign(:app_users, Accounts.list_users())
     |> assign_connections()
     |> assign_new_form()
     |> load_emby_users()}
  end

  @impl true
  def handle_event("validate", %{"connection" => params}, socket) do
    changeset = Integrations.change_connection(%Connection{}, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"connection" => params}, socket) do
    case Integrations.create_connection(params) do
      {:ok, connection} ->
        {:noreply,
         socket
         |> assign_connections()
         |> assign_new_form()
         |> put_flash(:info, "Connection #{connection.name} added.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    connection = Integrations.get_connection!(id)

    socket =
      case Integrations.check_connection(connection) do
        {:ok, connection} ->
          put_flash(socket, :info, "#{connection.name} responded — connection ok.")

        {:error, connection, reason} ->
          put_flash(socket, :error, "#{connection.name} failed: #{inspect(reason)}")
      end

    {:noreply, assign_connections(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, connection} = Integrations.delete_connection(Integrations.get_connection!(id))

    {:noreply,
     socket
     |> assign_connections()
     |> put_flash(:info, "Connection #{connection.name} removed.")}
  end

  def handle_event("map_emby", %{"mapping" => %{"user_id" => user_id} = mapping}, socket) do
    user = Accounts.get_user!(user_id)
    emby_id = if mapping["emby_user_id"] == "", do: nil, else: mapping["emby_user_id"]
    emby_name = emby_id && emby_user_name(socket.assigns.emby_users, emby_id)

    {:ok, user} = Accounts.map_emby_user(user, emby_id, emby_name)

    message =
      if emby_id,
        do: "#{handle(user)} mapped to Emby user #{emby_name}.",
        else: "#{handle(user)} unmapped from Emby."

    {:noreply,
     socket
     |> assign(:app_users, Accounts.list_users())
     |> put_flash(:info, message)}
  end

  def handle_event("map_trakt", %{"trakt" => %{"user_id" => user_id, "username" => username}}, socket) do
    {:ok, user} = Accounts.set_trakt_username(Accounts.get_user!(user_id), username)

    message =
      if user.trakt_username,
        do: "#{handle(user)} mapped to trakt user #{user.trakt_username}.",
        else: "#{handle(user)} unmapped from trakt."

    {:noreply,
     socket
     |> assign(:app_users, Accounts.list_users())
     |> put_flash(:info, message)}
  end

  def handle_event("import_trakt", %{"user-id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)

    case Oban.insert(MediaAssist.Media.TraktImportWorker.new(%{"user_id" => user.id})) do
      {:ok, _job} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Importing #{user.trakt_username}'s trakt history — new titles land as 'seen, not held' and get embedded."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue import: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_async(:load_emby_users, {:ok, result}, socket) do
    case result do
      {:ok, users} -> {:noreply, assign(socket, emby_users: users, emby_users_state: :ok)}
      {:error, reason} -> {:noreply, assign(socket, emby_users_state: {:error, reason})}
    end
  end

  def handle_async(:load_emby_users, {:exit, reason}, socket) do
    {:noreply, assign(socket, emby_users_state: {:error, reason})}
  end

  defp load_emby_users(socket) do
    if connected?(socket) do
      socket
      |> assign(:emby_users_state, :loading)
      |> start_async(:load_emby_users, fn -> Integrations.list_emby_users() end)
    else
      socket
    end
  end

  defp assign_connections(socket) do
    assign(socket, :connections, Integrations.list_connections())
  end

  defp assign_new_form(socket) do
    assign(socket, :form, to_form(Integrations.change_connection(%Connection{})))
  end

  defp emby_user_name(emby_users, emby_id) do
    Enum.find_value(emby_users || [], fn %{id: id, name: name} -> id == emby_id && name end)
  end

  # Select options: unmapped first, then live Emby users; a stale saved
  # mapping (user renamed/removed in Emby) stays visible as its raw id.
  defp emby_options(emby_users, current_id) do
    live = for %{id: id, name: name} <- emby_users || [], do: {name, id}

    stale =
      if current_id && !Enum.any?(live, fn {_name, id} -> id == current_id end),
        do: [{"#{current_id} (not on server)", current_id}],
        else: []

    [{"— unmapped", ""}] ++ live ++ stale
  end

  defp emby_comment(:loading), do: "querying emby for its user list…"
  defp emby_comment(:ok), do: "watch history is collected per mapped user"

  defp emby_comment({:error, :no_emby_connection}),
    do: "add an emby connection above to enable mapping"

  defp emby_comment({:error, reason}),
    do: "emby user list unavailable (#{inspect(reason)})"

  defp handle(user), do: user.email |> String.split("@") |> hd()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_scope={@current_scope} active_nav="settings">
      <SettingsComponents.settings_shell active="connections">
        <CompositeComponents.command_header command="settings connections --list">
          <:comment>
            radarr/sonarr feed the index; sabnzbd reports downloads; emby brings watch
            history; trakt or tmdb power tv discovery
          </:comment>
        </CompositeComponents.command_header>

        <CompositeComponents.empty_state
          :if={@connections == []}
          icon="hero-server-stack"
          title="No services connected"
        >
          Add your first arrstack service below — the media index stays empty until
          Radarr or Sonarr is connected.
        </CompositeComponents.empty_state>

        <ul
          :if={@connections != []}
          class="divide-y divide-base-content/10 border border-base-content/10 bg-base-200 text-sm"
        >
          <li
            :for={connection <- @connections}
            class="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-2.5"
          >
            <span class={[
              "select-none",
              connection.status == "ok" && "text-primary",
              connection.status == "error" && "text-error",
              connection.status == "unknown" && "text-base-content/30"
            ]}>
              ●
            </span>
            <span class="font-medium">{connection.name}</span>
            <span class="bg-base-300 px-1.5 py-0.5 text-xs text-base-content/70">
              {connection.service}
            </span>
            <span class="min-w-0 flex-1 truncate text-xs text-base-content/50">
              {connection.base_url}
            </span>
            <span :if={connection.last_checked_at} class="text-xs text-base-content/40">
              checked {Calendar.strftime(connection.last_checked_at, "%Y-%m-%d %H:%M")}
            </span>
            <.button size="sm" phx-click="test" phx-value-id={connection.id} phx-disable-with="…">
              test
            </.button>
            <.button
              size="sm"
              phx-click="delete"
              phx-value-id={connection.id}
              data-confirm={"Remove #{connection.name}? Cached media stays in the index."}
            >
              remove
            </.button>
          </li>
        </ul>

        <div class="max-w-md space-y-4 border-t border-base-content/10 pt-6">
          <p class="text-sm">
            <span class="select-none text-base-content/40">$ </span>
            <span class="font-medium text-accent">settings connections --add</span>
          </p>
          <.form
            for={@form}
            id="connection-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:service]}
                type="select"
                label="Service"
                options={Connection.services()}
              />
              <.input
                field={@form[:name]}
                type="text"
                label="Name"
                placeholder="radarr-main"
                spellcheck="false"
              />
            </div>
            <.input
              field={@form[:base_url]}
              type="text"
              label="Address"
              placeholder="http://192.168.1.20:7878"
              spellcheck="false"
            />
            <.input field={@form[:api_key]} type="password" label="API key" autocomplete="off" />
            <.button variant="primary" phx-disable-with="Adding…">Add connection</.button>
          </.form>
        </div>

        <div class="max-w-md space-y-4 border-t border-base-content/10 pt-6">
          <div class="space-y-0.5">
            <p class="text-sm">
              <span class="select-none text-base-content/40">$ </span>
              <span class="font-medium text-accent">settings connections --map-emby-users</span>
            </p>
            <p class="text-xs text-base-content/45">
              <span class="select-none"># </span>{emby_comment(@emby_users_state)}
            </p>
          </div>

          <ul :if={@emby_users_state == :ok} class="space-y-3">
            <li :for={user <- @app_users}>
              <.form
                for={to_form(%{}, as: :mapping)}
                id={"emby-mapping-#{user.id}"}
                phx-change="map_emby"
              >
                <.input type="hidden" name="mapping[user_id]" value={user.id} />
                <.input
                  type="select"
                  name="mapping[emby_user_id]"
                  label={"#{handle(user)}@media_assist"}
                  value={user.emby_user_id}
                  options={emby_options(@emby_users, user.emby_user_id)}
                />
              </.form>
            </li>
          </ul>
        </div>

        <div
          :if={Enum.any?(@connections, &(&1.service == "trakt"))}
          class="max-w-md space-y-4 border-t border-base-content/10 pt-6"
        >
          <div class="space-y-0.5">
            <p class="text-sm">
              <span class="select-none text-base-content/40">$ </span>
              <span class="font-medium text-accent">settings connections --map-trakt-users</span>
            </p>
            <p class="text-xs text-base-content/45">
              <span class="select-none"># </span>
              imports the full watched history — seen titles enter the catalog even when not held
            </p>
          </div>

          <ul class="space-y-3">
            <li :for={user <- @app_users} class="space-y-2">
              <.form
                for={to_form(%{}, as: :trakt)}
                id={"trakt-mapping-#{user.id}"}
                phx-change="map_trakt"
              >
                <.input type="hidden" name="trakt[user_id]" value={user.id} />
                <.input
                  type="text"
                  name="trakt[username]"
                  label={"#{handle(user)}@media_assist — trakt username"}
                  value={user.trakt_username}
                  phx-debounce="600"
                  spellcheck="false"
                  autocomplete="off"
                  placeholder="trakt.tv username (public profile)"
                />
              </.form>
              <.button
                :if={user.trakt_username}
                size="sm"
                phx-click="import_trakt"
                phx-value-user-id={user.id}
                phx-disable-with="queuing…"
              >
                import history
              </.button>
            </li>
          </ul>
        </div>
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end
end
