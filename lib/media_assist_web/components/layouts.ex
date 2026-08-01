defmodule MediaAssistWeb.Layouts do
  @moduledoc """
  Layouts for MediaAssistWeb.

  The app shell is one terminal session: a tmux-style status bar on top
  (nav as numbered windows), the page workspace in between, and the chat
  riser docked at the bottom of every page. Pages compose
  `<Layouts.app flash={@flash} current_scope={@current_scope}>...` from
  inside their LiveView render.
  """
  use MediaAssistWeb, :html

  alias MediaAssistWeb.ChatComponents
  alias MediaAssistWeb.CompositeComponents

  embed_templates "layouts/*"

  @nav_links [
    %{key: "feed", label: "feed", href: "/", index: 0},
    %{key: "library", label: "library", href: "/library", index: 1},
    %{key: "requests", label: "requests", href: "/requests", index: 2},
    %{key: "discover", label: "discover", href: "/discover", index: 3},
    %{key: "design", label: "design", href: "/design", index: 8},
    %{key: "custom-designs", label: "custom", href: "/custom-designs", index: 9}
  ]

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :active_nav, :string, default: nil

  attr :socket, :any,
    default: nil,
    doc: "Pass `@socket` so the chat riser mounts as a sticky nested LiveView."

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :handle, handle(assigns.current_scope))

    ~H"""
    <div class="relative flex min-h-dvh flex-col bg-base-100">
      <div class="sticky top-0 z-40">
        <CompositeComponents.status_bar active={@active_nav} links={nav_links()}>
          <:session>
            <%= if @current_scope do %>
              <span class="hidden text-base-content/70 sm:inline">{@handle}@media_assist</span>
              <.link navigate={~p"/settings"} class="hover:text-base-content">settings</.link>
              <.link href={~p"/users/log-out"} method="delete" class="hover:text-base-content">
                log out
              </.link>
            <% else %>
              <span class="hidden text-base-content/40 sm:inline">guest session</span>
              <.link href={~p"/users/log-in"} class="hover:text-base-content">log in</.link>
              <.link href={~p"/users/register"} class="text-accent hover:text-accent/80">
                register
              </.link>
            <% end %>
          </:session>
        </CompositeComponents.status_bar>
      </div>

      <main class="flex-1 pb-16">
        {render_slot(@inner_block)}
      </main>

      {@socket && live_render(@socket, MediaAssistWeb.ChatLive, id: "chat-riser-live", sticky: true)}
      <ChatComponents.chat_riser :if={!@socket} id="chat-riser" handle={@handle} />

      <JobyKit.CoreComponents.flash_group flash={@flash} />
    </div>
    """
  end

  defp nav_links, do: @nav_links

  defp handle(%{user: %{email: email}}) when is_binary(email) do
    email |> String.split("@") |> hd()
  end

  defp handle(_), do: "guest"
end
