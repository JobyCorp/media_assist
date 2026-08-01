defmodule MediaAssistWeb.SettingsLive.Tokens do
  @moduledoc """
  `/settings/tokens` — bearer tokens for the MCP endpoint. Lists the
  current user's tokens, generates new ones in a modal (the plaintext is
  shown exactly once, then exists only on the clipboard), and revokes.
  Revoked rows stay listed, dimmed — rows are never deleted.
  """

  use MediaAssistWeb, :live_view

  alias MediaAssist.Accounts
  alias MediaAssistWeb.CompositeComponents
  alias MediaAssistWeb.SettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "settings/tokens", modal: :closed)
     |> assign_tokens()
     |> assign_form()}
  end

  @impl true
  def handle_event("open_generate", _params, socket) do
    {:noreply, socket |> assign(:modal, :form) |> assign_form()}
  end

  def handle_event("close_modal", _params, socket) do
    # Dropping the assign is what destroys the plaintext — it lives
    # nowhere else.
    {:noreply, assign(socket, :modal, :closed)}
  end

  def handle_event("generate", %{"token" => params}, socket) do
    case Accounts.create_api_token(current_user(socket), params) do
      {:ok, plaintext, _token} ->
        {:noreply, socket |> assign(:modal, {:created, plaintext}) |> assign_tokens()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :token, action: :insert))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case Accounts.revoke_api_token(current_user(socket), id) do
      {:ok, token} ->
        {:noreply, socket |> assign_tokens() |> put_flash(:info, "Token #{token.name} revoked.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Token not found.")}
    end
  end

  defp current_user(socket), do: socket.assigns.current_scope.user

  defp assign_tokens(socket) do
    assign(socket, :tokens, Accounts.list_api_tokens(current_user(socket)))
  end

  defp assign_form(socket) do
    assign(socket, :form, to_form(%{"name" => ""}, as: :token))
  end

  defp plaintext({:created, plaintext}), do: plaintext

  defp last_used(%{last_used_at: nil}), do: "never"
  defp last_used(%{last_used_at: at}), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_scope={@current_scope} active_nav="settings">
      <SettingsComponents.settings_shell active="tokens">
        <CompositeComponents.command_header command="settings tokens --list" tone="accent">
          <:comment>
            bearer tokens for the MCP endpoint — the plaintext is shown once, at generation
          </:comment>
          <:actions>
            <.button size="sm" variant="primary" phx-click="open_generate">generate</.button>
          </:actions>
        </CompositeComponents.command_header>

        <CompositeComponents.empty_state :if={@tokens == []} icon="hero-key" title="No API tokens">
          Generate a token to connect an MCP client, then point it at
          <span class="font-medium">POST /mcp</span>
          with an Authorization bearer header.
        </CompositeComponents.empty_state>

        <ul
          :if={@tokens != []}
          class="divide-y divide-base-content/10 border border-base-content/10 bg-base-200 text-sm"
        >
          <li
            :for={token <- @tokens}
            class={[
              "flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-2.5",
              token.revoked_at && "opacity-50"
            ]}
          >
            <span class={["select-none", (token.revoked_at && "text-error") || "text-primary"]}>
              ●
            </span>
            <span class="font-medium">{token.name}</span>
            <span class="bg-base-300 px-1.5 py-0.5 text-xs text-base-content/70">
              {token.prefix}…
            </span>
            <span class="min-w-0 flex-1"></span>
            <span class="text-xs text-base-content/40">
              created:{Calendar.strftime(token.inserted_at, "%Y-%m-%d")}
            </span>
            <span class="text-xs text-base-content/40">last_used:{last_used(token)}</span>
            <span :if={token.revoked_at} class="text-xs text-error/70">revoked</span>
            <.button
              :if={!token.revoked_at}
              size="sm"
              phx-click="revoke"
              phx-value-id={token.id}
              data-confirm={"Revoke #{token.name}? Clients using it lose access immediately."}
            >
              revoke
            </.button>
          </li>
        </ul>

        <CompositeComponents.modal
          id="generate-token-modal"
          show={@modal != :closed}
          on_cancel="close_modal"
        >
          <:title>tokens generate</:title>

          <.form
            :if={@modal == :form}
            for={@form}
            id="token-form"
            phx-submit="generate"
            class="space-y-4"
          >
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="claude-code"
              spellcheck="false"
              autocomplete="off"
            />
            <.button variant="primary" phx-disable-with="generating…">Generate token</.button>
          </.form>

          <div :if={match?({:created, _}, @modal)} class="space-y-4">
            <p class="text-xs text-base-content/45">
              <span class="select-none"># </span>shown once — store it now
            </p>
            <div class="flex items-center gap-2">
              <code
                id="generated-token"
                class="min-w-0 flex-1 break-all border border-base-content/20 bg-base-300 px-3 py-2 text-xs"
              >{plaintext(@modal)}</code>
              <.button
                id="copy-token"
                size="sm"
                phx-hook=".CopyToClipboard"
                data-copy={plaintext(@modal)}
                data-target="generated-token"
              >
                copy
              </.button>
            </div>
            <.button phx-click="close_modal">done</.button>
          </div>
        </CompositeComponents.modal>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
          export default {
            mounted() {
              this.el.addEventListener("click", async () => {
                const label = this.el.textContent
                try {
                  await navigator.clipboard.writeText(this.el.dataset.copy)
                  this.el.textContent = "copied"
                } catch {
                  // Clipboard API unavailable (insecure context) or blocked:
                  // select the token so a manual copy is one keystroke away.
                  const target = document.getElementById(this.el.dataset.target)
                  if (target) {
                    const range = document.createRange()
                    range.selectNodeContents(target)
                    const selection = window.getSelection()
                    selection.removeAllRanges()
                    selection.addRange(range)
                  }
                  this.el.textContent = "press ctrl+c"
                }
                setTimeout(() => (this.el.textContent = label), 2000)
              })
            }
          }
        </script>
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end
end
