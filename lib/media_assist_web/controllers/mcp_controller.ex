defmodule MediaAssistWeb.McpController do
  @moduledoc """
  Stateless Streamable HTTP MCP server: a JSON-RPC dispatch on
  `POST /mcp`, tools only. No sessions, no SSE, no server-initiated
  messages — every request is answered with a plain JSON body, which is
  all a tools-only server needs. Auth happens upstream in
  `MediaAssistWeb.McpAuth`.

  Domain failures (title not found, duplicate request) come back as
  `isError: true` tool results so the calling agent can read them;
  JSON-RPC errors are reserved for protocol misuse.
  """

  use MediaAssistWeb, :controller

  alias MediaAssist.MCP.Tools

  # Newest first — initialize echoes the client's version when we
  # support it, otherwise offers our newest.
  @protocol_versions ~w(2025-06-18 2025-03-26)

  def handle(conn, %{"_json" => _batch}) do
    rpc_error(conn, nil, -32600, "batch requests are not supported")
  end

  def handle(conn, %{"method" => "notifications/" <> _rest}) do
    send_resp(conn, 202, "")
  end

  def handle(conn, %{"method" => method} = params) do
    id = params["id"]

    case dispatch(method, params["params"] || %{}, conn.assigns.current_scope) do
      {:ok, result} -> json(conn, %{jsonrpc: "2.0", id: id, result: result})
      {:error, code, message} -> rpc_error(conn, id, code, message)
    end
  end

  def handle(conn, _params) do
    rpc_error(conn, nil, -32600, "invalid JSON-RPC request")
  end

  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  defp dispatch("initialize", params, _scope) do
    requested = params["protocolVersion"]
    version = if requested in @protocol_versions, do: requested, else: hd(@protocol_versions)

    {:ok,
     %{
       protocolVersion: version,
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{
         name: "media_assist",
         version: to_string(Application.spec(:media_assist, :vsn))
       },
       instructions:
         "Tools over the media_assist catalog: search/list what the household " <>
           "holds, request new titles, and query similarity. Requests are " <>
           "submitted to Radarr/Sonarr as the token's user."
     }}
  end

  defp dispatch("ping", _params, _scope), do: {:ok, %{}}

  defp dispatch("tools/list", _params, _scope), do: {:ok, %{tools: Tools.descriptors()}}

  defp dispatch("tools/call", %{"name" => name} = params, scope) do
    case Tools.call(name, params["arguments"] || %{}, scope) do
      {:ok, payload} ->
        {:ok, %{content: [%{type: "text", text: Jason.encode!(payload)}], isError: false}}

      {:error, :unknown_tool} ->
        {:error, -32602, "unknown tool: #{name}"}

      {:error, message} when is_binary(message) ->
        {:ok, %{content: [%{type: "text", text: message}], isError: true}}
    end
  end

  defp dispatch("tools/call", _params, _scope), do: {:error, -32602, "missing tool name"}

  defp dispatch(method, _params, _scope), do: {:error, -32601, "method not found: #{method}"}

  defp rpc_error(conn, id, code, message) do
    json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
  end
end
