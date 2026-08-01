defmodule MediaAssistWeb.DesignPreviews do
  @moduledoc """
  Per-component preview functions referenced by `MediaAssistWeb.DesignManifest`.

  Each public function takes `assigns` (typically `%{}`) and returns a
  small HEEx rendering the component with sensible defaults. The
  manifest registers these via `preview: &MediaAssistWeb.DesignPreviews.X_preview/1`,
  and `JobyKit.SignatureComponent` invokes them inside the per-component
  card's collapsible Preview section.

  Naming convention: every preview function ends in `_preview` so they
  don't collide with the imported component functions of the same name
  (e.g. `button` vs `button_preview`).

  The previews call `JobyKit.CoreComponents` directly via the
  `CoreComponents` alias so the rendered HTML matches what the manifest
  declares — no dependency on the host's `<App>Web.CoreComponents`
  resolution.
  """

  use MediaAssistWeb, :html

  alias JobyKit.CoreComponents
  alias MediaAssistWeb.ChatComponents
  alias MediaAssistWeb.CompositeComponents
  alias MediaAssistWeb.MediaComponents

  def button_preview(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <CoreComponents.button>Default</CoreComponents.button>
      <CoreComponents.button variant="primary">Primary</CoreComponents.button>
      <CoreComponents.button size="sm">Small</CoreComponents.button>
      <CoreComponents.button size="lg">Large</CoreComponents.button>
    </div>
    """
  end

  def card_preview(assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <CoreComponents.card>
        <:eyebrow>Bordered</:eyebrow>
        <:title>Default card</:title>
        Padded content surface backed by daisyUI's <code class="font-mono text-xs">card</code>.
        <:actions><CoreComponents.button>Action</CoreComponents.button></:actions>
      </CoreComponents.card>
      <CoreComponents.card variant="elevated">
        <:eyebrow>Elevated</:eyebrow>
        <:title>Card with shadow</:title>
        Lifts on hover via the wrapper's transition.
      </CoreComponents.card>
    </div>
    """
  end

  def icon_preview(assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-base-content/80">
      <CoreComponents.icon name="hero-sparkles" />
      <CoreComponents.icon name="hero-arrow-right" class="size-5" />
      <CoreComponents.icon name="hero-bolt" class="size-7 text-primary" />
    </div>
    """
  end

  def input_preview(assigns) do
    assigns =
      assigns
      |> Map.put(:form, Phoenix.Component.to_form(%{"email" => ""}, as: :preview))

    ~H"""
    <div class="flex max-w-md flex-col gap-3">
      <CoreComponents.input field={@form[:email]} type="email" label="Email" />
      <CoreComponents.input
        name="bio"
        value=""
        type="textarea"
        label="Bio"
        placeholder="Tell us about yourself"
      />
    </div>
    """
  end

  def flash_preview(assigns) do
    assigns = Map.put(assigns, :preview_flash, %{"info" => "Saved.", "error" => "Try again."})

    ~H"""
    <div class="relative flex flex-col gap-2">
      <CoreComponents.flash kind={:info} flash={@preview_flash} />
      <CoreComponents.flash kind={:error} flash={@preview_flash} title="Heads up" />
    </div>
    """
  end

  def empty_state_preview(assigns) do
    ~H"""
    <div class="grid gap-4 sm:grid-cols-2">
      <CompositeComponents.empty_state icon="hero-inbox" title="No messages yet">
        Start a conversation with a teammate to see it here.
        <:action>
          <CoreComponents.button variant="primary">New message</CoreComponents.button>
        </:action>
      </CompositeComponents.empty_state>
      <CompositeComponents.empty_state
        icon="hero-sparkles"
        title="Set up your workspace"
        tone="primary"
      >
        Connect your first integration to populate this dashboard.
      </CompositeComponents.empty_state>
    </div>
    """
  end

  def command_header_preview(assigns) do
    ~H"""
    <div class="flex flex-col gap-6">
      <CompositeComponents.command_header command="recommend --user jody --limit 8">
        <:comment>tuned to your last 30 days of watch history</:comment>
      </CompositeComponents.command_header>
      <CompositeComponents.command_header command="requests --active --all-users" tone="accent">
        <:comment>what the household is waiting on right now</:comment>
        <:actions>
          <CoreComponents.button size="sm">refresh</CoreComponents.button>
        </:actions>
      </CompositeComponents.command_header>
    </div>
    """
  end

  def status_bar_preview(assigns) do
    ~H"""
    <CompositeComponents.status_bar
      active="feed"
      links={[
        %{key: "feed", label: "feed", href: "/", index: 0},
        %{key: "library", label: "library", href: "/", index: 1, soon: true},
        %{key: "requests", label: "requests", href: "/", index: 2, soon: true}
      ]}
    >
      <:session>
        <span class="text-base-content/70">settings</span>
        <span class="text-base-content/70">log out</span>
      </:session>
    </CompositeComponents.status_bar>
    """
  end

  def tree_nav_preview(assigns) do
    ~H"""
    <CompositeComponents.tree_nav
      title="~/settings"
      active="connections"
      items={[
        %{key: "ai-gateway", label: "ai-gateway", href: "/settings/ai-gateway"},
        %{key: "connections", label: "connections", href: "/settings/connections"},
        %{key: "index", label: "index", href: "/settings/index"},
        %{key: "account", label: "account", href: "/users/settings", external: true}
      ]}
    />
    """
  end

  def settings_shell_preview(assigns) do
    ~H"""
    <MediaAssistWeb.SettingsComponents.settings_shell active="index">
      <CompositeComponents.command_header command="settings index --edit">
        <:comment>page content renders in the right column</:comment>
      </CompositeComponents.command_header>
      <p class="text-sm text-base-content/60">
        Every /settings page composes this shell; the account entry exits to the
        sudo-style user management.
      </p>
    </MediaAssistWeb.SettingsComponents.settings_shell>
    """
  end

  def media_card_preview(assigns) do
    ~H"""
    <div class="grid max-w-2xl grid-cols-2 gap-3 sm:grid-cols-3">
      <MediaComponents.media_card
        title="Blade Runner 2049"
        year={2017}
        kind="movie"
        status="in_library"
        score={96}
        note="because you watched Dune: Part Two"
      />
      <MediaComponents.media_card
        title="Coherence"
        year={2013}
        kind="movie"
        status="requested"
        score={87}
        note="kate requested this yesterday"
      />
      <MediaComponents.media_card
        title="Scavengers Reign"
        year={2023}
        kind="series"
        status="missing"
        score={85}
      />
    </div>
    """
  end

  def chat_riser_preview(assigns) do
    ~H"""
    <ChatComponents.chat_riser
      id="chat-riser-preview"
      handle="jody"
      docked={false}
      data-riser-open
      phx-no-format
    ><:message role="system">model online — connected to radarr, sonarr, prowlarr</:message><:message role="user">what did kate add this week?</:message><:message role="assistant">3 titles: Dune: Part Two, Shōgun, and Poor Things. Shōgun is the closest match to your taste — want it in your watchlist?</:message></ChatComponents.chat_riser>
    """
  end

  def chat_line_preview(assigns) do
    ~H"""
    <div class="space-y-2 bg-base-300 p-4 text-sm" phx-no-format>
      <ChatComponents.chat_line role="system">session started</ChatComponents.chat_line>
      <ChatComponents.chat_line role="user" handle="jody">request Perfect Days in 4k</ChatComponents.chat_line>
      <ChatComponents.chat_line role="assistant">Queued Perfect Days (2023) — 2160p profile. Radarr is searching 3 indexers.</ChatComponents.chat_line>
    </div>
    """
  end
end
