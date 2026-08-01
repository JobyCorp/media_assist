defmodule MediaAssistWeb.CompositeComponents do
  @moduledoc """
  Generic, multi-primitive composites for this app.

  Composites live one layer above core wrappers: they bundle a small set
  of `JobyKit.CoreComponents` primitives into a higher-level pattern that
  appears more than once across the app. Examples: empty states, page
  headers with breadcrumbs, callouts, hero blocks.

  Every composite follows the JobyKit wrapper contract:

    1. Declare every prop with `attr` (use `values:` for variant enums).
    2. Carry a `data-component` attribute naming
       `MediaAssistWeb.CompositeComponents.<name>` on the root element.
    3. Accept `attr :rest, :global` for id/class/aria-*/phx-* pass-through.
    4. Internals compose `JobyKit.CoreComponents` (or other registered
       wrappers) — never raw `<button>`/`<input>`/`<textarea>`.
    5. Register the composite in `MediaAssistWeb.DesignManifest`
       (`category: :composite`) so it surfaces on `/custom-designs` and
       in `/design.json`.

  The `empty_state/1` below ships pre-registered as a worked example.
  Use it as a template when you add your own composites: copy the
  attribute / slot / `data-component` shape, then register the new entry
  in the manifest.
  """

  use MediaAssistWeb, :html

  alias JobyKit.CoreComponents

  @doc """
  A section header styled as an executed shell command. Encodes where a
  block of content came from: the command line names the operation that
  produced the rows beneath it.

      <.command_header command="recommend --user jody --limit 8">
        <:comment>tuned to your last 30 days of watch history</:comment>
      </.command_header>
  """
  attr :command, :string, required: true, doc: "The command text, without the leading `$`."

  attr :tone, :string,
    values: ~w(primary accent),
    default: "primary",
    doc: "Color of the command text. `accent` marks request/queue operations."

  attr :rest, :global

  slot :comment, doc: "Optional dim `# comment` line under the command."
  slot :actions, doc: "Optional right-aligned controls."

  def command_header(assigns) do
    ~H"""
    <div
      data-component="MediaAssistWeb.CompositeComponents.command_header"
      class="flex flex-wrap items-end justify-between gap-2 border-b border-base-content/10 pb-2"
      {@rest}
    >
      <div class="min-w-0 space-y-0.5">
        <p class="text-sm">
          <span class="select-none text-base-content/40">$ </span>
          <span class={[
            "font-medium",
            @tone == "primary" && "text-primary",
            @tone == "accent" && "text-accent"
          ]}>{@command}</span>
        </p>
        <p :if={@comment != []} class="text-xs text-base-content/45">
          <span class="select-none"># </span>{render_slot(@comment)}
        </p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  tmux-style session status bar: brand block on the left, nav links as
  numbered windows, session identity on the right. Lives at the top of
  `Layouts.app`.

  Links are maps with `:key`, `:label`, `:href`, an optional numeric
  `:index` (window number), and optional `soon: true` for planned pages
  rendered as inert markers.

      <.status_bar
        active="feed"
        links={[%{key: "feed", label: "feed", href: "/", index: 0}]}
      >
        <:session>jody@media_assist</:session>
      </.status_bar>
  """
  attr :brand, :string, default: "media_assist"
  attr :active, :string, default: nil
  attr :links, :list, required: true
  attr :rest, :global

  slot :session, doc: "Right side of the bar — identity and auth links."

  def status_bar(assigns) do
    ~H"""
    <nav
      data-component="MediaAssistWeb.CompositeComponents.status_bar"
      class="flex h-11 items-stretch gap-4 border-b border-base-content/10 bg-base-200 px-4 text-sm"
      {@rest}
    >
      <.link navigate="/" class="flex items-center font-semibold text-accent">
        {@brand}
      </.link>
      <ul class="flex min-w-0 flex-1 items-stretch gap-1 overflow-x-auto">
        <li :for={link <- @links} class="flex items-stretch whitespace-nowrap">
          <span
            :if={link[:soon]}
            class="flex cursor-default items-center gap-1 px-2 text-base-content/30"
            title="coming soon"
          >
            <span :if={link[:index]}>{link.index}:</span>{link.label}<span class="text-[0.65rem]">·soon</span>
          </span>
          <.link
            :if={!link[:soon]}
            navigate={link.href}
            class={[
              "flex items-center gap-0 px-2 transition-colors",
              @active == link.key && "bg-base-100 text-primary",
              @active != link.key && "text-base-content/60 hover:text-base-content"
            ]}
          >
            <span :if={link[:index]} class="text-base-content/40">{link.index}:</span>{link.label}<span
              :if={@active == link.key}
              class="text-primary"
            >*</span>
          </.link>
        </li>
      </ul>
      <div :if={@session != []} class="flex items-center gap-3 text-xs text-base-content/60">
        {render_slot(@session)}
      </div>
    </nav>
    """
  end

  @doc """
  A directory-tree side nav: a root label with box-drawing branches to
  each entry. Encodes that the pages are siblings under one path.

      <.tree_nav
        title="~/settings"
        active="connections"
        items={[
          %{key: "ai-gateway", label: "ai-gateway", href: "/settings/ai-gateway"},
          %{key: "account", label: "account", href: "/users/settings", external: true}
        ]}
      />

  Entries with `external: true` render with a `↗` marker — they leave
  the tree (e.g. the sudo-style account pages).
  """
  attr :title, :string, required: true, doc: "Root of the tree, e.g. `~/settings`."
  attr :active, :string, default: nil
  attr :items, :list, required: true
  attr :rest, :global

  def tree_nav(assigns) do
    ~H"""
    <nav
      data-component="MediaAssistWeb.CompositeComponents.tree_nav"
      class="text-sm leading-7"
      {@rest}
    >
      <p class="font-semibold text-base-content">{@title}</p>
      <ul>
        <li :for={{item, index} <- Enum.with_index(@items)} class="flex">
          <span class="select-none whitespace-pre text-base-content/30">{branch(index, length(@items))}</span>
          <.link
            navigate={item.href}
            class={[
              @active == item.key && "text-primary",
              @active != item.key && "text-base-content/60 hover:text-base-content"
            ]}
          >
            {item.label}<span :if={@active == item.key}>*</span><span
              :if={item[:external]}
              class="text-base-content/40"
            > ↗</span>
          </.link>
        </li>
      </ul>
    </nav>
    """
  end

  defp branch(index, count) when index == count - 1, do: "└─ "
  defp branch(_index, _count), do: "├─ "

  @doc """
  An empty-state callout: centered icon, title, supporting text, and an
  optional action slot. Use to fill an otherwise-empty container — an
  unfilled list, a search with no results, a fresh dashboard.

      <.empty_state icon="hero-inbox" title="No messages yet">
        Start a conversation with a teammate to see it here.
        <:action>
          <CoreComponents.button variant="primary">New message</CoreComponents.button>
        </:action>
      </.empty_state>
  """
  attr :icon, :string,
    default: "hero-sparkles",
    doc: "Heroicon name to display above the title."

  attr :title, :string, required: true
  attr :tone, :string, values: ~w(neutral primary), default: "neutral"
  attr :rest, :global

  slot :inner_block, doc: "Supporting copy beneath the title."
  slot :action, doc: "Optional call-to-action (typically a `<.button>`)."

  def empty_state(assigns) do
    ~H"""
    <div
      data-component="MediaAssistWeb.CompositeComponents.empty_state"
      class={[
        "flex flex-col items-center justify-center gap-3 border border-dashed px-6 py-10 text-center",
        @tone == "neutral" && "border-base-300 bg-base-100/40 text-base-content/70",
        @tone == "primary" && "border-primary/30 bg-primary/5 text-base-content"
      ]}
      {@rest}
    >
      <span class={[
        "flex size-12 items-center justify-center",
        @tone == "neutral" && "bg-base-200 text-base-content/60",
        @tone == "primary" && "bg-primary/10 text-primary"
      ]}>
        <CoreComponents.icon name={@icon} class="size-6" />
      </span>
      <h3 class="text-base font-semibold text-base-content">{@title}</h3>
      <div :if={@inner_block != []} class="max-w-sm text-sm text-base-content/65">
        {render_slot(@inner_block)}
      </div>
      <div :if={@action != []} class="pt-1">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  A server-controlled modal over the daisyUI `modal` primitive. Rendered
  only while `show` is true; `on_cancel` names the LiveView event pushed
  by the ✕ button, the backdrop, and Escape — the caller owns the state.

      <.modal id="token-modal" show={@modal_open} on_cancel="close_modal">
        <:title>tokens generate</:title>
        ...body...
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, :string, required: true, doc: "LiveView event name pushed to dismiss."
  attr :rest, :global

  slot :title, required: true, doc: "Rendered as the modal's `$ command` line."
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id={@id}
      data-component="MediaAssistWeb.CompositeComponents.modal"
      class="modal modal-open"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
      role="dialog"
      aria-modal="true"
      {@rest}
    >
      <div class="modal-box max-w-md rounded-none border border-base-content/20 bg-base-200 shadow-none">
        <div class="mb-4 flex items-start justify-between gap-4">
          <p class="text-sm">
            <span class="select-none text-base-content/40">$ </span>
            <span class="font-medium text-accent">{render_slot(@title)}</span>
          </p>
          <CoreComponents.button size="sm" phx-click={@on_cancel} aria-label="close">
            ✕
          </CoreComponents.button>
        </div>
        {render_slot(@inner_block)}
      </div>
      <div class="modal-backdrop bg-base-300/60" phx-click={@on_cancel} aria-hidden="true"></div>
    </div>
    """
  end
end
