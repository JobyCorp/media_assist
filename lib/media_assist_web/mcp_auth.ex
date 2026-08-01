defmodule MediaAssistWeb.McpAuth do
  @moduledoc """
  Bearer-token auth for the MCP endpoint. Verifies the `Authorization`
  header against `Accounts.verify_api_token/1` and assigns the token
  owner's `current_scope` — MCP calls act as that user. Anything else
  halts with 401.
  """

  import Plug.Conn

  alias MediaAssist.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- Accounts.verify_api_token(token) do
      assign(conn, :current_scope, Accounts.Scope.for_user(user))
    else
      _unauthorized ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: nil,
            error: %{code: -32001, message: "unauthorized: pass a valid API token as a bearer"}
          })
        )
        |> halt()
    end
  end
end
