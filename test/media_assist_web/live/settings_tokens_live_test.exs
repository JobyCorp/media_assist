defmodule MediaAssistWeb.SettingsTokensLiveTest do
  use MediaAssistWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MediaAssist.Accounts

  describe "when not logged in" do
    test "redirects to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/settings/tokens")
    end
  end

  describe "/settings/tokens" do
    setup :register_and_log_in_user

    test "shows the empty state without tokens", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/tokens")

      assert html =~ "No API tokens"
    end

    test "generates a token in the modal and shows the plaintext once", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/settings/tokens")

      lv |> element("button", "generate") |> render_click()

      html =
        lv
        |> form("#token-form", token: %{name: "claude-code"})
        |> render_submit()

      assert [%{name: "claude-code", prefix: "ma_" <> _}] = Accounts.list_api_tokens(user)
      assert html =~ "store it now"
      assert html =~ "ma_"

      # closing the modal drops the plaintext for good
      html = lv |> element("button", "done") |> render_click()
      refute html =~ "store it now"
      assert html =~ "claude-code"
      assert html =~ "ma_"
    end

    test "keeps the modal open with errors on a blank name", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/settings/tokens")

      lv |> element("button", "generate") |> render_click()

      html =
        lv
        |> form("#token-form", token: %{name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Accounts.list_api_tokens(user) == []
    end

    test "revokes a token and keeps the row, dimmed", %{conn: conn, user: user} do
      {:ok, _plaintext, token} = Accounts.create_api_token(user, %{"name" => "old-client"})

      {:ok, lv, html} = live(conn, ~p"/settings/tokens")
      assert html =~ "old-client"
      refute html =~ "revoked"

      html =
        lv
        |> element(~s{button[phx-value-id="#{token.id}"]}, "revoke")
        |> render_click()

      assert html =~ "revoked"
      assert html =~ "old-client"
      assert [%{revoked_at: %DateTime{}}] = Accounts.list_api_tokens(user)
    end

    test "does not list other users' tokens", %{conn: conn} do
      other = MediaAssist.AccountsFixtures.user_fixture()
      {:ok, _plaintext, _token} = Accounts.create_api_token(other, %{"name" => "not-mine"})

      {:ok, _lv, html} = live(conn, ~p"/settings/tokens")
      refute html =~ "not-mine"
    end
  end
end
