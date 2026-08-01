defmodule MediaAssistWeb.SettingsLive.AiGateway do
  @moduledoc """
  `/settings/ai-gateway` — how the app reaches the airo gateway. Saves
  the singleton `Integrations.GatewaySettings`; "test gateway" lists the
  gateway's models through `AiroClient` as a connectivity check.

  The chat/embedding model selects are fed by the gateway's own model
  catalog (bucketed by capability), loaded async on mount and refreshed
  after save/test. Until the catalog is reachable, each select carries
  only the saved value.
  """

  use MediaAssistWeb, :live_view

  alias MediaAssist.Integrations
  alias MediaAssistWeb.CompositeComponents
  alias MediaAssistWeb.SettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    settings = Integrations.get_gateway_settings()

    {:ok,
     socket
     |> assign(
       page_title: "settings/ai-gateway",
       settings: settings,
       models: nil,
       models_state: :loading,
       form: to_form(Integrations.change_gateway_settings(settings))
     )
     |> load_models()}
  end

  @impl true
  def handle_event("validate", %{"gateway_settings" => params}, socket) do
    changeset = Integrations.change_gateway_settings(socket.assigns.settings, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"gateway_settings" => params}, socket) do
    case Integrations.update_gateway_settings(keep_saved_token(params, socket)) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(
           settings: settings,
           form: to_form(Integrations.change_gateway_settings(settings))
         )
         |> load_models()
         |> put_flash(:info, "Gateway settings saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("test", _params, socket) do
    socket = load_models(socket)

    case Integrations.test_gateway(socket.assigns.settings) do
      {:ok, models} when is_list(models) ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Gateway reachable — #{length(models)} models: #{Enum.join(models, ", ")}"
         )}

      {:error, :not_configured} ->
        {:noreply, put_flash(socket, :error, "Save a base URL and token first.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Gateway unreachable: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_async(:load_models, {:ok, result}, socket) do
    case result do
      {:ok, models} -> {:noreply, assign(socket, models: models, models_state: :ok)}
      {:error, reason} -> {:noreply, assign(socket, models_state: {:error, reason})}
    end
  end

  def handle_async(:load_models, {:exit, reason}, socket) do
    {:noreply, assign(socket, models_state: {:error, reason})}
  end

  defp load_models(socket) do
    if connected?(socket) do
      settings = socket.assigns.settings

      socket
      |> assign(:models_state, :loading)
      |> start_async(:load_models, fn -> Integrations.list_gateway_models(settings) end)
    else
      socket
    end
  end

  # A blank token field means "keep the saved token", not "clear it".
  defp keep_saved_token(%{"token" => ""} = params, socket) do
    if socket.assigns.settings.token, do: Map.delete(params, "token"), else: params
  end

  defp keep_saved_token(params, _socket), do: params

  # Catalog ids for the capability, always including the saved value so
  # the select never loses the current configuration.
  defp model_options(models, capability, current) do
    (List.wrap(current) ++ ((models || %{})[capability] || []))
    |> Enum.uniq()
  end

  defp models_comment(:loading, _models), do: "querying the gateway model catalog…"

  defp models_comment(:ok, models),
    do:
      "#{length(models.chat)} chat · #{length(models.embeddings)} embedding models from the gateway"

  defp models_comment({:error, :not_configured}, _models),
    do: "save a gateway URL and token to load selectable models"

  defp models_comment({:error, reason}, _models),
    do: "model catalog unavailable (#{inspect(reason)}) — showing saved values"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_scope={@current_scope} active_nav="settings">
      <SettingsComponents.settings_shell active="ai-gateway">
        <CompositeComponents.command_header command="settings ai-gateway --edit">
          <:comment>
            the assistant, embeddings, and the recommender all route through airo
          </:comment>
        </CompositeComponents.command_header>

        <.form
          for={@form}
          id="gateway-form"
          phx-change="validate"
          phx-submit="save"
          class="max-w-md space-y-4"
        >
          <.input
            field={@form[:base_url]}
            type="text"
            label="Gateway URL"
            placeholder="http://airo.internal:4000"
            spellcheck="false"
          />
          <.input
            field={@form[:token]}
            type="password"
            label={if @settings.token, do: "Token (saved — leave blank to keep)", else: "Token"}
            value=""
            autocomplete="off"
          />
          <div class="space-y-1">
            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:chat_model]}
                type="select"
                label="Chat model"
                options={model_options(@models, :chat, @form[:chat_model].value)}
              />
              <.input
                field={@form[:embedding_model]}
                type="select"
                label="Embedding model"
                options={model_options(@models, :embeddings, @form[:embedding_model].value)}
              />
            </div>
            <p class="text-xs text-base-content/40">
              <span class="select-none"># </span>{models_comment(@models_state, @models)}
            </p>
          </div>
          <.input field={@form[:enabled]} type="checkbox" label="Gateway enabled" />
          <div class="pt-2">
            <.button variant="primary" phx-disable-with="Saving…">Save gateway</.button>
          </div>
        </.form>
        <div class="max-w-md">
          <.button phx-click="test" phx-disable-with="Testing…">Test gateway</.button>
        </div>
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end
end
