<!-- jobykit:start -->
## JobyKit — read this before writing UI

This project uses [JobyKit](https://github.com/jobycorp/joby_kit). Every UI
primitive flows through a registered wrapper. Skipping the wrapper layer is
the failure mode this kit exists to prevent.

### Hard rules

1. **No raw `<button>`, `<input>`, `<textarea>`, `<select>` in `.heex`** unless
   the surrounding `def` is itself a registered wrapper definition. The kit
   ships `<.button>`, `<.input>`, `<.icon>`, `<.card>`, `<.flash>`, etc.;
   reach for those, or register a new wrapper.
2. **Every new component carries the contract**: typed `attr` declarations
   with `values:` enums for variants, `data-component="Module.function"` on
   the root element, `attr :rest, :global` for pass-through. Register it in
   `<App>Web.DesignManifest`.
3. **Run `mix joby_kit.lint` before claiming done.** It checks the contract
   end-to-end; the `:raw_html_primitive` rule will catch step 1 violations.

### Symptoms you skipped step 1

If any of these are true, you bypassed the wrapper contract — stop and
lift the offending markup into a wrapper:

- You wrote `<button class="…">` when `<.button>` exists.
- You styled a private function component as if it were a primitive.
- You added a new component without `data-component`, without
  `attr :rest, :global`, or without a `DesignManifest` entry.
- The same `class="…"` string appears on the same semantic UI element on
  more than one page.

### What the kit ships

Core wrappers (registered against `JobyKit.CoreComponents` in the
manifest):

- `<.button>` — text/link button with variant + size
- `<.card>` — content surface with eyebrow/title/actions slots
- `<.icon>` — Heroicon span (`name="hero-..."`)
- `<.input>` — form input (text/email/select/textarea/checkbox/...)
- `<.flash>`, `<.flash_group>` — toast-style flashes
- `<.header>`, `<.list>`, `<.table>`

The host-shipped scaffold also registers a worked composite example
(`<App>Web.CompositeComponents.empty_state`) so there's a precedent for
"this is how you extend." Pattern-match on it before reaching for raw
markup.

### When you genuinely need raw HTML

Inside a wrapper definition (a `def` whose root carries `data-component`),
raw HTML primitives are the wrapper's body — that's how wrappers work.
For one-off cases outside wrapper territory, append
`<%!-- jobykit:allow-raw-html --%>` on the same or immediately preceding
line to silence the lint rule.

### Discoverability

- `curl http://localhost:PORT/design.json` — machine-readable manifest
- `/design` — kit-curated wrapper previews
- `/custom-designs` — this app's composites and domain components
- `AGENTS.md` → "JobyKit guidelines" — full build order and rationale

### Build order (in order, every time)

1. Domain composite exists? Use it.
2. Generic composite exists? Use it.
3. Core wrapper exists? Use it.
4. daisyUI primitive exists? Wrap it (register in `DesignManifest`), then use.
5. None of the above? Tailwind + theme tokens; expose the result as a
   wrapper or composite and register it.
<!-- jobykit:end -->

## Data conventions

- **binary_id everywhere.** The Users context already uses UUID keys; every
  new context must too. Hand-written schemas `use MediaAssist.Schema`
  (never `use Ecto.Schema` directly) — it sets
  `@primary_key {:id, :binary_id, autogenerate: true}`,
  `@foreign_key_type :binary_id`, and UTC timestamps. Generators are
  configured with `binary_id: true` in `config/config.exs`. Migrations
  create tables with `primary_key: false` and
  `add :id, :binary_id, primary_key: true`.

- **`media_items` is a catalog, not a mirror of disk.** Presence is the
  `status` field (`in_library`/`missing`/`departed`/`known`) — rows are
  never deleted when titles leave the arrs, so embeddings, watches, and
  graph edges survive. Two exclusion sets, never conflated: "seen"
  (watch rows — recommender) vs "held" (`Media.held_provider_ids/1` —
  discovery/requests dedupe).
- **Secrets are encrypted at rest.** API keys and tokens use
  `MediaAssist.Encrypted.Binary` (Cloak) on a `:binary` column — never a
  plain `:string`. Dev/test keys are static in config; prod reads
  `CLOAK_KEY` in runtime.exs.
- **Singleton settings rows** (gateway, index) follow the
  `Integrations` pattern: `get_*` returns the row or a default struct,
  `update_*` upserts via `Repo.insert_or_update`.
- **External HTTP goes through a client module** (`Integrations.ArrClient`,
  `MediaAssist.AI.Gateway` wrapping AiroClient) — LiveViews and workers
  never call Req/AiroClient directly.

## Design language

The app is a terminal session. Keep new UI inside this system:

- **One typeface**: JetBrains Mono. Hierarchy comes from weight, size,
  case, and color — never from a second font family.
- **Palette**: phosphor slate (dark only). `primary` = tempered phosphor
  green (library/success states), `accent` = amber (the prompt, cursors,
  request/queue states), `error` = soft red. Square corners, 1px hairline
  borders, no shadows/depth/noise.
- **Structure encodes meaning**: nav items are tmux-style windows
  (`0:feed`), feed sections open with a `command_header` showing the
  command that produced them, metadata renders as `key:value` pairs.
- **The chat riser** (`ChatComponents.chat_riser`) is the app's signature
  element and lives in `Layouts.app` on every page. Don't add competing
  chat entry points; new chat features extend the riser.
- **Restraint**: no scanlines, glow, or CRT effects. The blinking cursor
  in the riser is the only ambient animation (respects reduced motion).
