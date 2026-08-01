defmodule MediaAssistWeb.McpControllerTest do
  use MediaAssistWeb.ConnCase, async: true
  use Oban.Testing, repo: MediaAssist.Repo

  import MediaAssist.AccountsFixtures

  alias MediaAssist.Accounts
  alias MediaAssist.Media

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, plaintext, token} = Accounts.create_api_token(user, %{"name" => "test-client"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> put_req_header("content-type", "application/json")

    %{conn: conn, user: user, plaintext: plaintext, token: token}
  end

  defp rpc(conn, method, params \\ %{}) do
    post(conn, ~p"/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end

  defp tool(conn, name, arguments \\ %{}) do
    response =
      conn
      |> rpc("tools/call", %{name: name, arguments: arguments})
      |> json_response(200)

    result = response["result"]
    [%{"type" => "text", "text" => text}] = result["content"]
    {result["isError"], Jason.decode!(text)}
  end

  defp tool_error(conn, name, arguments) do
    response =
      conn
      |> rpc("tools/call", %{name: name, arguments: arguments})
      |> json_response(200)

    assert %{"isError" => true, "content" => [%{"text" => text}]} = response["result"]
    text
  end

  defp item_fixture(attrs) do
    defaults = %{
      kind: "movie",
      title: "Blade Runner 2049",
      year: 2017,
      service: "radarr",
      service_item_id: System.unique_integer([:positive])
    }

    {:ok, item} = Media.upsert_item(Map.merge(defaults, attrs))
    item
  end

  describe "auth" do
    test "rejects a missing token", %{conn: conn} do
      conn = delete_req_header(conn, "authorization")
      assert conn |> rpc("ping") |> json_response(401)
    end

    test "rejects a bogus token", %{conn: conn} do
      conn = put_req_header(conn, "authorization", "Bearer ma_not-a-real-token")
      assert conn |> rpc("ping") |> json_response(401)
    end

    test "rejects a revoked token", %{conn: conn, user: user, token: token} do
      {:ok, _revoked} = Accounts.revoke_api_token(user, token.id)
      assert conn |> rpc("ping") |> json_response(401)
    end

    test "GET is method-not-allowed", %{conn: conn} do
      conn = get(conn, ~p"/mcp")
      assert response(conn, 405)
      assert get_resp_header(conn, "allow") == ["POST"]
    end
  end

  describe "protocol" do
    test "initialize echoes a supported protocol version", %{conn: conn} do
      response =
        conn |> rpc("initialize", %{protocolVersion: "2025-03-26"}) |> json_response(200)

      assert %{
               "protocolVersion" => "2025-03-26",
               "serverInfo" => %{"name" => "media_assist"},
               "capabilities" => %{"tools" => %{}}
             } = response["result"]
    end

    test "initialize offers our newest version to an unknown one", %{conn: conn} do
      response = conn |> rpc("initialize", %{protocolVersion: "1999-01-01"}) |> json_response(200)
      assert response["result"]["protocolVersion"] == "2025-06-18"
    end

    test "notifications get 202 with no body", %{conn: conn} do
      conn =
        post(
          conn,
          ~p"/mcp",
          Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"})
        )

      assert response(conn, 202) == ""
    end

    test "ping pongs", %{conn: conn} do
      assert %{"result" => %{}} = conn |> rpc("ping") |> json_response(200)
    end

    test "unknown methods are -32601", %{conn: conn} do
      response = conn |> rpc("resources/list") |> json_response(200)
      assert %{"error" => %{"code" => -32601}} = response
    end

    test "batches are rejected", %{conn: conn} do
      conn = post(conn, ~p"/mcp", Jason.encode!([%{jsonrpc: "2.0", id: 1, method: "ping"}]))
      assert %{"error" => %{"code" => -32600}} = json_response(conn, 200)
    end

    test "unknown tools are -32602", %{conn: conn} do
      response = conn |> rpc("tools/call", %{name: "rm_rf", arguments: %{}}) |> json_response(200)
      assert %{"error" => %{"code" => -32602}} = response
    end
  end

  describe "tools/list" do
    test "lists the six tools with schemas", %{conn: conn} do
      response = conn |> rpc("tools/list") |> json_response(200)
      names = Enum.map(response["result"]["tools"], & &1["name"])

      assert Enum.sort(names) ==
               ~w(get_media list_media media_status request_media search_media similar_media)

      assert Enum.all?(response["result"]["tools"], & &1["inputSchema"])
    end
  end

  describe "list_media" do
    test "lists held items, filterable by kind", %{conn: conn} do
      item_fixture(%{title: "Alien"})
      item_fixture(%{title: "The Wire", kind: "series", service: "sonarr", tvdb_id: 79126})

      assert {false, %{"items" => items, "total" => 2}} = tool(conn, "list_media")

      assert {false, %{"items" => [%{"title" => "The Wire"}], "total" => 1}} =
               tool(conn, "list_media", %{kind: "series"})

      assert Enum.map(items, & &1["title"]) == ["Alien", "The Wire"]
    end

    test "status filter reaches beyond held titles", %{conn: conn} do
      item_fixture(%{title: "Long Gone", status: "departed"})

      assert {false, %{"total" => 0}} = tool(conn, "list_media")
      assert {false, %{"total" => 1}} = tool(conn, "list_media", %{status: "departed"})
    end
  end

  describe "get_media" do
    test "returns full detail with watchers", %{conn: conn, user: user} do
      item = item_fixture(%{title: "Heat", overview: "Cops and robbers.", tmdb_id: 949})
      {:ok, _watch} = Media.upsert_watch(user, item, %{play_count: 2})

      assert {false, detail} = tool(conn, "get_media", %{id: item.id})
      assert detail["overview"] == "Cops and robbers."
      assert detail["tmdb_id"] == 949
      assert [%{"play_count" => 2}] = detail["watchers"]
    end

    test "unknown id is a readable tool error", %{conn: conn} do
      assert tool_error(conn, "get_media", %{id: Ecto.UUID.generate()}) =~ "no catalog item"
    end
  end

  describe "search_media" do
    test "searches the catalog", %{conn: conn} do
      item_fixture(%{title: "Blade Runner"})
      item_fixture(%{title: "Blade Runner 2049"})
      item_fixture(%{title: "Amélie"})

      assert {false, %{"library" => results}} = tool(conn, "search_media", %{query: "blade"})
      assert length(results) == 2
    end

    test "include_new without kind is a readable error", %{conn: conn} do
      assert tool_error(conn, "search_media", %{query: "dune", include_new: true}) =~
               "requires kind"
    end

    test "include_new without an arr connection is a readable error", %{conn: conn} do
      assert tool_error(conn, "search_media", %{
               query: "dune",
               kind: "movie",
               include_new: true
             }) =~ "no radarr connection"
    end
  end

  describe "request_media" do
    test "creates a pending request as the token's user and queues the add",
         %{conn: conn, user: user} do
      assert {false, payload} =
               tool(conn, "request_media", %{
                 kind: "movie",
                 title: "Dark City",
                 year: 1998,
                 tmdb_id: 2666
               })

      assert %{"status" => "pending", "title" => "Dark City"} = payload

      assert [request] = MediaAssist.Requests.list_recent_requests(5)
      assert request.user_id == user.id

      assert_enqueued(
        worker: MediaAssist.Requests.AddWorker,
        args: %{"request_id" => request.id}
      )
    end

    test "changeset failures come back readable", %{conn: conn} do
      assert tool_error(conn, "request_media", %{kind: "movie", title: "No Id"}) =~ "tmdb_id"

      assert {false, _payload} =
               tool(conn, "request_media", %{kind: "movie", title: "Dupe", tmdb_id: 42})

      assert tool_error(conn, "request_media", %{kind: "movie", title: "Dupe", tmdb_id: 42}) =~
               "request rejected"
    end
  end

  describe "media_status" do
    test "returns the system snapshot", %{conn: conn} do
      item_fixture(%{title: "Alien"})
      {false, _payload} = tool(conn, "request_media", %{kind: "movie", title: "Dune", tmdb_id: 1})

      assert {false, status} = tool(conn, "media_status")
      assert status["catalog"]["movies"] == 1
      assert [%{"title" => "Dune", "status" => "pending"}] = status["recent_requests"]
      assert status["download_queue"] == nil
      assert %{"watches" => 0} = status["watches"]
    end
  end

  describe "similar_media" do
    test "returns embedding neighbors for a seed title", %{conn: conn} do
      {:ok, _seed} = Media.put_embedding(item_fixture(%{title: "Alien"}), [1.0, 0.0])
      {:ok, _near} = Media.put_embedding(item_fixture(%{title: "Aliens"}), [0.9, 0.1])
      {:ok, _far} = Media.put_embedding(item_fixture(%{title: "Notting Hill"}), [0.0, 1.0])

      assert {false, %{"seed" => %{"title" => "Alien"}, "similar" => similar}} =
               tool(conn, "similar_media", %{title: "Alien", limit: 2})

      assert [%{"title" => "Aliens"}, %{"title" => "Notting Hill"}] = similar
      assert hd(similar)["distance"] < List.last(similar)["distance"]
    end

    test "a seed without an embedding is a readable error", %{conn: conn} do
      item = item_fixture(%{title: "Fresh Import"})
      assert tool_error(conn, "similar_media", %{id: item.id}) =~ "no embedding"
    end

    test "an unknown seed is a readable error", %{conn: conn} do
      assert tool_error(conn, "similar_media", %{title: "zzz nope"}) =~ "no catalog item"
    end
  end
end
