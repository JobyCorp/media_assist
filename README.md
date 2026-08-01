# MediaAssist

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## MCP server

The app exposes its catalog to agents over MCP (stateless Streamable
HTTP, tools only) at `POST /mcp`. Tools: `list_media`, `get_media`,
`search_media`, `request_media`, `media_status`, `similar_media`.

Generate a bearer token at `/settings/tokens` (shown once), then:

```sh
claude mcp add media-assist --transport http http://localhost:4000/mcp \
  --header "Authorization: Bearer ma_…"
```

Requests made through `request_media` are submitted to Radarr/Sonarr as
the token's owning user, same flow as the UI. Revoking the token at
`/settings/tokens` cuts access immediately. Design details in
`docs/specs/mcp-server-api-tokens.md`.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
