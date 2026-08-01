defmodule MediaAssistWeb.DesignManifest do
  @moduledoc """
  This app's component manifest. Backed by `JobyKit.Manifest`.

  The default registrations point at `JobyKit.CoreComponents` — the kit
  ships the standard scaffolding (`button`, `card`, `icon`, `input`,
  `flash`, `header`, `list`, `table`) so every JobyKit-installed app
  gets contract-clean wrappers for free.

  Add a `component/3` line for every additional wrapper, composite, and
  domain component you want to surface on `/design` and
  `/custom-designs`. The JSON manifest at `/design.json` combines all
  entries.
  """

  use JobyKit.Manifest

  alias JobyKit.CoreComponents
  alias MediaAssistWeb.CompositeComponents
  alias MediaAssistWeb.DesignPreviews

  category(:core,
    label: "Core wrappers",
    description: "One wrapper per daisyUI primitive. Ship by JobyKit."
  )

  category(:composite,
    label: "Generic composites",
    description: "Multi-primitive patterns reused across domains."
  )

  category(:domain,
    label: "Domain composites",
    description: "Composites tied to a product area."
  )

  # ---------------------------------------------------------------------- core
  # The kit-shipped scaffolding. Each component carries the wrapper
  # contract (data-component, attr :rest, :global, attrs with values:
  # enums) and is lint-clean by construction.

  component(CoreComponents, :button,
    category: :core,
    daisy_basis: "btn",
    summary: "Standard text button, with link auto-detection via :rest.",
    preview: &DesignPreviews.button_preview/1
  )

  component(CoreComponents, :card,
    category: :core,
    daisy_basis: "card",
    summary: "Padded content surface with eyebrow, title, and actions slots.",
    preview: &DesignPreviews.card_preview/1
  )

  component(CoreComponents, :icon,
    category: :core,
    daisy_basis: "hero-*",
    summary: "Heroicon span. Pass `name=\"hero-x-mark\"` and an optional `class`.",
    preview: &DesignPreviews.icon_preview/1
  )

  component(CoreComponents, :input,
    category: :core,
    daisy_basis: "input / select / textarea / checkbox",
    summary: "Form input with label and error rendering. Supports all standard input types.",
    preview: &DesignPreviews.input_preview/1
  )

  component(CoreComponents, :flash,
    category: :core,
    daisy_basis: "alert",
    summary: "Toast-style flash notice. Use inside `flash_group/1` from your root layout.",
    preview: &DesignPreviews.flash_preview/1
  )

  # ----------------------------------------------------------------- composite
  # `empty_state` is the worked example — a real composite that bundles
  # `<.icon>` + a heading + an optional action slot. Use it as the
  # template for your own composites: copy the attr / slot / data-component
  # shape, register the new entry here, and add a preview in
  # `design_previews.ex`. Generic composites belong in
  # `MediaAssistWeb.CompositeComponents`; domain-specific ones in
  # their own module (e.g. `MediaAssistWeb.ChatComponents`).

  component(CompositeComponents, :empty_state,
    category: :composite,
    summary: "Centered icon + title + optional action; fills empty containers.",
    preview: &DesignPreviews.empty_state_preview/1
  )

  component(CompositeComponents, :command_header,
    category: :composite,
    summary: "Section header styled as an executed shell command, with optional # comment.",
    preview: &DesignPreviews.command_header_preview/1
  )

  component(CompositeComponents, :status_bar,
    category: :composite,
    summary: "tmux-style session bar: brand, nav as numbered windows, session identity.",
    preview: &DesignPreviews.status_bar_preview/1
  )

  component(CompositeComponents, :tree_nav,
    category: :composite,
    summary: "Directory-tree side nav: root label with box-drawing branches per entry.",
    preview: &DesignPreviews.tree_nav_preview/1
  )

  # -------------------------------------------------------------------- domain

  component(MediaAssistWeb.MediaComponents, :media_card,
    category: :domain,
    summary: "Feed card for a movie/series: poster, ASCII match meter, library status.",
    preview: &DesignPreviews.media_card_preview/1
  )

  component(MediaAssistWeb.ChatComponents, :chat_riser,
    category: :domain,
    summary: "The bottom-docked terminal chat. Collapsed prompt line rises into a transcript.",
    preview: &DesignPreviews.chat_riser_preview/1
  )

  component(MediaAssistWeb.SettingsComponents, :settings_shell,
    category: :domain,
    summary: "Two-column frame for /settings pages: ~/settings tree nav + content.",
    preview: &DesignPreviews.settings_shell_preview/1
  )

  component(MediaAssistWeb.ChatComponents, :chat_line,
    category: :domain,
    summary: "One transcript line: user lines carry the prompt, system lines are # comments.",
    preview: &DesignPreviews.chat_line_preview/1
  )

  @doc """
  Tells `JobyKit.DaisyCatalogue` which daisyUI primitives this app has
  wrapped, so the catalogue rendering flips them to `:wrapped` and links
  to the signature card on the index. The atoms must match
  `JobyKit.DaisyCatalogue` ids (`:button`, `:badge`, `:card`, …).
  """
  def daisy_overrides do
    %{
      button: %{
        wrapper: "<.button>",
        anchor: "#jobykit-component-jobykit-corecomponents-button"
      },
      card: %{
        wrapper: "<.card>",
        anchor: "#jobykit-component-jobykit-corecomponents-card"
      }
    }
  end
end
