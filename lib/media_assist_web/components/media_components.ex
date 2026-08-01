defmodule MediaAssistWeb.MediaComponents do
  @moduledoc """
  Domain composites for the media library: cards, shelves, and status
  readouts for movies and series surfaced by the arrstack.

  Every component follows the JobyKit wrapper contract (typed `attr`
  declarations, `data-component` on the root, `attr :rest, :global`) and
  is registered in `MediaAssistWeb.DesignManifest` under `:domain`.
  """

  use MediaAssistWeb, :html

  @poster_tones [
    "from-primary/25 to-base-300",
    "from-accent/25 to-base-300",
    "from-info/25 to-base-300",
    "from-secondary/30 to-base-300",
    "from-error/20 to-base-300"
  ]

  @doc """
  A media card for the discovery feed: 2:3 poster area, title, and
  metadata rendered as terminal `key:value` pairs. When no `poster_url`
  is given, the poster area falls back to a tonal panel derived from the
  title.

      <.media_card title="Blade Runner 2049" year={2017} kind="movie" status="in_library" score={96} />
  """
  attr :title, :string, required: true
  attr :year, :integer, default: nil
  attr :kind, :string, values: ~w(movie series), default: "movie"

  attr :status, :string,
    values: ~w(in_library requested missing departed known) ++ [nil],
    default: "missing",
    doc:
      "Library state: green when present, amber while requested, dim when absent. " <>
        "Pass nil to omit the line (e.g. discovery cards with their own action)."

  attr :score, :integer,
    default: nil,
    doc: "Recommendation match 0–100, rendered as an ASCII meter."

  attr :rt, :any,
    default: nil,
    doc: "Rotten Tomatoes score, shown as a dim `rt:88` in the meta row."

  attr :note, :string,
    default: nil,
    doc: "One dim context line, e.g. why the AI recommended this."

  attr :poster_url, :string, default: nil

  attr :navigate, :string,
    default: nil,
    doc: "When set, the whole card links to this path (stretched link)."

  attr :rest, :global

  slot :action, doc: "Optional control row at the card's foot (e.g. a request button)."

  def media_card(assigns) do
    assigns =
      assign(
        assigns,
        :tone,
        Enum.at(@poster_tones, :erlang.phash2(assigns.title, length(@poster_tones)))
      )

    ~H"""
    <article
      data-component="MediaAssistWeb.MediaComponents.media_card"
      class="group/card relative flex flex-col border border-base-content/10 bg-base-200 transition-colors hover:border-base-content/30"
      {@rest}
    >
      <.link :if={@navigate} navigate={@navigate} aria-label={@title} class="absolute inset-0 z-10"></.link>
      <div class={[
        "relative aspect-[2/3] overflow-hidden border-b border-base-content/10",
        !@poster_url && "bg-gradient-to-br #{@tone}"
      ]}>
        <img
          :if={@poster_url}
          src={@poster_url}
          alt={"Poster for #{@title}"}
          class="size-full object-cover"
          loading="lazy"
        />
        <span
          :if={!@poster_url}
          class="absolute inset-0 flex items-center justify-center text-5xl font-bold text-base-content/25"
          aria-hidden="true"
        >
          {String.first(@title)}
        </span>
        <span class="absolute left-1.5 top-1.5 bg-base-300/90 px-1.5 py-0.5 text-[0.65rem] text-base-content/70">
          {@kind}
        </span>
      </div>
      <div class="space-y-1 p-2.5 text-xs">
        <h3 class="truncate text-sm font-medium text-base-content" title={@title}>{@title}</h3>
        <p class="text-base-content/50">
          <span :if={@year}>{@year}</span><span :if={@year && @score} class="text-base-content/25">
            ·
          </span><span :if={@score} class="text-primary/80">{score_meter(@score)} {@score}</span><span
            :if={@rt && (@year || @score)}
            class="text-base-content/25"
          > · </span><span :if={@rt} class="text-base-content/45">rt:{round(@rt)}</span>
        </p>
        <p
          :if={@status}
          class={[
            @status == "in_library" && "text-primary/90",
            @status == "requested" && "text-accent",
            @status in ["missing", "departed", "known"] && "text-base-content/40"
          ]}
        >
          {status_label(@status)}
        </p>
        <p :if={@note} class="truncate text-base-content/40" title={@note}>↳ {@note}</p>
        <div :if={@action != []} class="relative z-20 pt-1.5">
          {render_slot(@action)}
        </div>
      </div>
    </article>
    """
  end

  defp score_meter(score) do
    filled = round(score / 20)
    String.duplicate("▓", filled) <> String.duplicate("░", 5 - filled)
  end

  defp status_label("in_library"), do: "✓ in library"
  defp status_label("requested"), do: "◌ requested"
  defp status_label("missing"), do: "+ request"
  defp status_label("departed"), do: "− departed"
  defp status_label("known"), do: "○ seen, not held"
end
