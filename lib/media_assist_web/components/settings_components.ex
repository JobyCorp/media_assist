defmodule MediaAssistWeb.SettingsComponents do
  @moduledoc """
  Domain composites for the `/settings` area. `settings_shell/1` is the
  two-column frame every settings page renders inside: the `~/settings`
  tree nav on the left, the page's content on the right.

  App settings live here (`/settings/*`); the `account ↗` entry exits to
  the sudo-style user management at `/users/settings`, which stays its
  own surface on purpose.
  """

  use MediaAssistWeb, :html

  alias MediaAssistWeb.CompositeComponents

  @items [
    %{key: "ai-gateway", label: "ai-gateway", href: "/settings/ai-gateway"},
    %{key: "connections", label: "connections", href: "/settings/connections"},
    %{key: "index", label: "index", href: "/settings/index"},
    %{key: "tokens", label: "tokens", href: "/settings/tokens"},
    %{key: "account", label: "account", href: "/users/settings", external: true}
  ]

  @doc """
  Frame for a settings page.

      <.settings_shell active="connections">
        ...page content...
      </.settings_shell>
  """
  attr :active, :string, required: true, values: ~w(ai-gateway connections index tokens)
  attr :rest, :global

  slot :inner_block, required: true

  def settings_shell(assigns) do
    assigns = assign(assigns, :items, @items)

    ~H"""
    <div
      data-component="MediaAssistWeb.SettingsComponents.settings_shell"
      class="mx-auto w-full max-w-5xl px-4 py-8 sm:px-6"
      {@rest}
    >
      <div class="grid gap-10 md:grid-cols-[11rem_minmax(0,1fr)]">
        <CompositeComponents.tree_nav
          title="~/settings"
          active={@active}
          items={@items}
          class="md:sticky md:top-16 md:self-start"
        />
        <section class="min-w-0 space-y-6">
          {render_slot(@inner_block)}
        </section>
      </div>
    </div>
    """
  end
end
