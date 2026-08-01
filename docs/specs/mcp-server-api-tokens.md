# Sprint spec — MCP server + API tokens

Status: **approved 2026-07-31** (open questions resolved: media_status =
system snapshot; no expiry; hand-rolled transport; request_media uses
the same auto-submit flow as the UI) · Author: Claude · Date: 2026-07-31

Two deliverables, shipped as one sprint because the second is the first's
auth story:

1. An MCP server (Streamable HTTP, tools-only) exposing the media catalog
   to agents, secured by bearer API tokens.
2. Token management at `/settings/tokens` — list, generate (modal with
   copy button), revoke.

---

## 1. API tokens

### Data model

New table `api_tokens`, new schema `MediaAssist.Accounts.ApiToken`
(`use MediaAssist.Schema` — binary_id, UTC timestamps):

| column       | type            | notes                                        |
|--------------|-----------------|----------------------------------------------|
| `id`         | `:binary_id`    | pk                                           |
| `user_id`    | `references`    | tokens act *as this user* (requests, watches attribute to them) |
| `name`       | `:string`       | required, user-supplied label ("claude-code") |
| `token_hash` | `:binary`       | `:crypto.hash(:sha256, raw)` — plaintext never stored |
| `prefix`     | `:string`       | first 12 chars of plaintext (`ma_ab12cd34`) for display/identification |
| `last_used_at` | `:utc_datetime` | touched on verify, throttled (see below)   |
| `revoked_at` | `:utc_datetime`  | null = active; rows never deleted (audit)   |

Plaintext format: `"ma_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)`.
Same hash-at-rest pattern as `UserToken.build_hashed_token/3` — DB
read access can't recover a usable token. No Cloak needed: we store a
one-way hash, not a recoverable secret.

No expiry. Homelab, revoke-only lifecycle. (Flagged as open question.)

### Context API (`MediaAssist.Accounts`, same module)

```elixir
create_api_token(user, name)      # ⇒ {:ok, plaintext, %ApiToken{}} — plaintext returned exactly once
list_api_tokens(user)             # all rows, active + revoked, newest first
revoke_api_token(user, id)        # sets revoked_at; idempotent
verify_api_token(plaintext)       # ⇒ {:ok, user} | :error — hash lookup, revoked_at must be nil
```

`verify_api_token/1` touches `last_used_at` at most once per minute
(skip the UPDATE when the current value is < 60s old) so hot agent
sessions don't write-amplify.

---

## 2. `/settings/tokens` UI

New LiveView `SettingsLive.Tokens` inside the existing
`:require_authenticated_user` live_session, rendered in
`SettingsComponents.settings_shell`. Nav: add
`%{key: "tokens", label: "tokens", href: "/settings/tokens"}` to
`@items` and to the `values:` enum on `settings_shell`'s `active` attr.

**List** — `<.table>` of the user's tokens: `name`, `prefix…`,
`key:value` metadata for created/last-used (design language), and state.
Revoked rows stay visible, dimmed, labeled `revoked`.

**Generate** — button opens a modal:

- No modal wrapper exists yet → per JobyKit build order rule 4, wrap the
  daisyUI `modal`/`<dialog>` primitive as a new core wrapper
  (`<.modal>` with `data-component`, typed attrs, `attr :rest, :global`)
  and register it in `DesignManifest`. Square corners, hairline border,
  no shadow — matches the terminal design language.
- Step 1: name input (`<.input>`) → submit.
- Step 2 (same modal): plaintext shown once in a monospace block with a
  copy button — new `CopyToClipboard` JS hook in `app.js`
  (`navigator.clipboard.writeText`, flips the button label to `copied`
  for ~2s). Warning line: *shown once — store it now.*
- Plaintext lives only in a socket assign; cleared when the modal closes.

**Revoke** — button per row with `data-confirm`. Revoke, not delete —
consistent with the catalog's rows-are-never-deleted convention.

`mix joby_kit.lint` must pass before the slice is done.

---

## 3. MCP server

### Transport: hand-rolled stateless Streamable HTTP

**Recommendation: no new dependency.** A tools-only MCP server over
stateless Streamable HTTP is a single JSON-RPC dispatch on
`POST /mcp` — no sessions, no SSE, no subscriptions. That's ~200 lines
we fully control, in line with this codebase's explicit-client-module
convention. The alternative (`anubis_mcp`, née `hermes_mcp`) earns its
keep only if we later want server-initiated messages/SSE streaming —
noted as the escape hatch, not the default.

Methods handled by `MediaAssistWeb.McpController`:

| method                       | behaviour                                              |
|------------------------------|--------------------------------------------------------|
| `initialize`                 | protocol version echo (support `2025-06-18` and `2025-03-26`), `capabilities: %{tools: %{listChanged: false}}`, `serverInfo: %{name: "media_assist", version: ...}` |
| `notifications/initialized`  | `202 Accepted`, empty body                             |
| `ping`                       | `{}`                                                   |
| `tools/list`                 | static tool descriptors (JSON Schema `inputSchema`)    |
| `tools/call`                 | dispatch to `MediaAssist.MCP.Tools`                    |
| anything else                | JSON-RPC `-32601` method not found                     |

`GET /mcp` → 405 (we don't offer a server-push stream). Tool results
return `content: [%{type: "text", text: Jason.encode!(payload)}]`.
Domain failures (not found, dedupe hit) return `isError: true` with a
readable message, not a JSON-RPC error.

### Auth

New `:mcp` pipeline: `plug :accepts, ["json"]` + `MediaAssistWeb.McpAuth`
plug — extract `Authorization: Bearer ma_…`, `verify_api_token/1`,
assign `current_scope` (`Accounts.Scope.for_user/1`); otherwise 401 with
`WWW-Authenticate: Bearer`. No session, no CSRF. Route sits in its own
scope:

```elixir
scope "/", MediaAssistWeb do
  pipe_through :mcp
  post "/mcp", McpController, :handle
end
```

### Tools (`MediaAssist.MCP.Tools`)

One module, one `call(name, args, scope)` dispatch; thin — every tool is
an existing context function. LiveView/worker rule applies: tools call
contexts, never Req/ArrClient directly *except* via the same paths the
UI already uses.

| tool            | maps to | args | returns |
|-----------------|---------|------|---------|
| `list_media`    | `Media.list_items/1` | `kind?` (movie/series), `status?` (in_library/missing/departed/known), `genre?`, `limit?` (default 25, max 100), `offset?` | compact rows: id, kind, title, year, status, genres |
| `get_media`     | `Media.fetch_item/1` + `Media.item_watchers/1` | `id` | full detail: overview, ratings, provider ids, poster, status, watchers |
| `search_media`  | `Media.search_items/1` first; when `include_new: true`, also `ArrClient.lookup/2` via the radarr/sonarr connection for `kind` | `query`, `kind?`, `include_new?` | candidates with tmdb/tvdb ids + flags: `in_library`, `already_requested` (from `held_provider_ids` + `requested_provider_ids` — the two exclusion sets, kept distinct) |
| `request_media` | `Requests.create_request/2` as the token's user | `kind`, `title`, `tmdb_id` (movie) / `tvdb_id` (series), `year?`, `poster_url?` | request row with status; changeset/dedupe errors surface as `isError` text |
| `media_status`  | `Media.stats/0`, `Media.watch_stats/0`, `Requests.list_recent_requests/1`, `ArrClient.fetch_sab_queue/1` when a sabnzbd connection exists | *(none)* | system snapshot: catalog counts by kind/status, recent watches, pending/failed requests, download queue |
| `similar_media` | `Media.similar_items_with_distance/2`; resolve `title` via `search_items` when no id given | `id?` \| `title?`, `limit?` (default 10) | neighbors with distance — pgvector, no AI-gateway call |

Deliberately *not* wiring `Discovery.discover/2` (AI-powered discovery)
into `similar_media` — it's slow, costs gateway tokens, and the agent on
the other end of MCP is itself an AI that can iterate on `search_media`.
Can be a `discover_media` tool in a later sprint if wanted.

### Client setup (docs)

README section: `claude mcp add media-assist --transport http
http://<host>:4000/mcp --header "Authorization: Bearer ma_…"`.

---

## 4. Slices (build order)

- **A — token backbone**: migration, `ApiToken` schema,
  `Accounts` functions, context tests (hashing, revoke, last_used
  throttle, verify rejects revoked).
- **B — `/settings/tokens`**: `<.modal>` wrapper + manifest entry,
  `CopyToClipboard` hook, LiveView + tests, nav entry,
  `mix joby_kit.lint`.
- **C — MCP endpoint**: auth plug + pipeline + controller with
  `initialize`/`tools/list` and plug/controller tests
  (401, bad JSON-RPC, happy path).
- **D — tools**: `MCP.Tools` dispatch, all six tools + tests
  (fixture-backed; ArrClient calls stubbed the way existing
  worker tests do it).
- **E — verify end-to-end**: generate a token in the UI, register the
  server with a real MCP client (Claude Code) against dev, exercise every
  tool, then revoke and confirm 401.

## 5. Open questions (answer before slice C/D)

1. **`media_status` semantics** — spec'd as *system-wide snapshot*
   (per-title status is already covered by `get_media`/`search_media`
   flags). Confirm that's the intent of "media status".
2. **Token expiry** — spec'd as non-expiring + revoke. Want optional
   expiries (30/90 days) instead?
3. **Transport choice** — hand-rolled stateless endpoint vs
   `anubis_mcp` dep. Spec recommends hand-rolled; flip if you'd rather
   own less protocol code.
4. **`request_media` guardrails** — requests from tokens are
   auto-submitted like UI requests (no approval gate). OK for the
   household, or should MCP-created requests start `pending` behind an
   approval you click in `/requests`?
