defmodule MediaAssistWeb.ChatComponents do
  @moduledoc """
  The chat riser and its message primitives — the app's signature
  element. The riser docks to the bottom of `Layouts.app` as a single
  prompt line and rises into a terminal transcript when opened.

  Client behavior (toggle, `/` to focus, `esc` to close) lives in the
  `TerminalRiser` hook in `assets/js/app.js`.

  Every component follows the JobyKit wrapper contract and is registered
  in `MediaAssistWeb.DesignManifest` under `:domain`.
  """

  use MediaAssistWeb, :html

  alias JobyKit.CoreComponents

  @doc """
  The chat riser. Collapsed, it is a one-line shell prompt pinned to the
  bottom of the viewport; open, it rises into a terminal session with a
  scrollback and an input line.

      <.chat_riser id="chat-riser" handle="jody">
        <:message role="user">what did kate add this week?</:message>
        <:message role="assistant">3 titles: ...</:message>
      </.chat_riser>

  Set `docked={false}` to render it in normal flow (used by previews).
  """
  attr :id, :string, required: true
  attr :handle, :string, default: "guest", doc: "Shell-style user name shown in the prompt."
  attr :docked, :boolean, default: true, doc: "Pin to the bottom of the viewport."

  attr :busy, :boolean,
    default: false,
    doc: "Assistant is thinking: shows a progress line, disables the input."

  attr :rest, :global

  slot :message do
    attr :role, :string, values: ~w(user assistant system)
  end

  def chat_riser(assigns) do
    ~H"""
    <section
      data-component="MediaAssistWeb.ChatComponents.chat_riser"
      id={@id}
      phx-hook="TerminalRiser"
      class={[
        "group/riser border-t border-base-content/15 bg-base-300",
        @docked && "fixed inset-x-0 bottom-0 z-40"
      ]}
      {@rest}
    >
      <button
        type="button"
        data-riser-toggle
        class="flex h-11 w-full cursor-pointer items-center gap-2 px-4 text-left text-sm"
        aria-expanded="false"
        aria-controls={"#{@id}-panel"}
      >
        <span class="select-none text-base-content/40 transition-transform group-data-[riser-open]/riser:rotate-180">
          ▲
        </span>
        <span class="flex min-w-0 flex-1 items-center gap-2 group-data-[riser-open]/riser:hidden">
          <span class="whitespace-nowrap">
            <span class="text-accent">{@handle}@media_assist</span><span class="text-base-content/40">:~$</span>
          </span>
          <span class="cursor-blink text-accent" aria-hidden="true">▮</span>
          <span class="truncate text-base-content/35">
            ask about the library, or request something new
          </span>
        </span>
        <span class="hidden min-w-0 flex-1 truncate text-base-content/50 group-data-[riser-open]/riser:inline">
          chat — <span class="text-accent">{@handle}@media_assist</span>
        </span>
        <span class="hidden shrink-0 text-xs text-base-content/30 sm:inline">
          <span class="group-data-[riser-open]/riser:hidden">[/] chat · </span>[esc] close
        </span>
      </button>

      <div
        id={"#{@id}-panel"}
        data-riser-panel
        class="hidden flex-col group-data-[riser-open]/riser:flex"
        style="height: min(26rem, 60vh)"
      >
        <div
          data-riser-scrollback
          class="flex-1 space-y-2 overflow-y-auto border-t border-base-content/10 px-4 py-3 text-sm"
          role="log"
          aria-label="Chat transcript"
          phx-no-format
        ><p :if={@message == []} class="text-base-content/40">
            # session started — nothing here yet. Ask a question or request a title.
          </p><.chat_line :for={msg <- @message} role={Map.get(msg, :role, "assistant")} handle={@handle}>{render_slot(msg)}</.chat_line><p :if={@busy} class="text-base-content/40">
            <span class="cursor-blink">▮</span> thinking…
          </p></div>
        <form
          data-riser-form
          phx-submit="send"
          class="flex items-center gap-2 border-t border-base-content/10 px-4 py-2.5 text-sm"
        >
          <label for={"#{@id}-input"} class="select-none whitespace-nowrap">
            <span class="text-accent">{@handle}@media_assist</span><span class="text-base-content/40">:~$</span>
          </label>
          <input
            id={"#{@id}-input"}
            data-riser-input
            name="text"
            type="text"
            autocomplete="off"
            spellcheck="false"
            disabled={@busy}
            placeholder={
              if @busy, do: "waiting for the model…", else: "find me something like Severance…"
            }
            class="w-full border-0 bg-transparent p-0 text-sm text-base-content placeholder:text-base-content/30 focus:outline-none focus:ring-0 disabled:opacity-50"
          />
          <CoreComponents.icon
            name="hero-arrow-turn-down-left"
            class="size-4 shrink-0 text-base-content/30"
          />
        </form>
      </div>
    </section>
    """
  end

  @doc """
  One line of the riser transcript. User lines carry the prompt prefix;
  assistant lines are plain output; system lines are dim `#` comments —
  exactly how a shell session distinguishes input from output.

  The content renders `whitespace-pre-wrap` so model line breaks
  survive — slot bodies must be written tight (no template indentation),
  e.g. `<.chat_line>{msg.content}</.chat_line>` on one line.
  """
  attr :role, :string, values: ~w(user assistant system), default: "assistant"
  attr :handle, :string, default: "guest"
  attr :rest, :global

  slot :inner_block, required: true

  def chat_line(assigns) do
    ~H"""
    <div
      data-component="MediaAssistWeb.ChatComponents.chat_line"
      class="flex gap-2 break-words"
      {@rest}
    >
      <span :if={@role == "user"} class="select-none whitespace-nowrap">
        <span class="text-accent">{@handle}</span><span class="text-base-content/40">$</span>
      </span>
      <span :if={@role == "system"} class="select-none text-base-content/40">#</span>
      <div
        class={[
          "min-w-0 whitespace-pre-wrap",
          @role == "user" && "text-base-content",
          @role == "assistant" && "text-base-content/75",
          @role == "system" && "text-base-content/40"
        ]}
        phx-no-format
      >{render_slot(@inner_block)}</div>
    </div>
    """
  end
end
