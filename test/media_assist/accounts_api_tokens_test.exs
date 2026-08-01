defmodule MediaAssist.AccountsApiTokensTest do
  use MediaAssist.DataCase, async: true

  import MediaAssist.AccountsFixtures

  alias MediaAssist.Accounts
  alias MediaAssist.Accounts.ApiToken

  describe "create_api_token/2" do
    test "returns the plaintext once and stores only its hash" do
      user = user_fixture()

      assert {:ok, plaintext, %ApiToken{} = token} =
               Accounts.create_api_token(user, %{"name" => "claude-code"})

      assert String.starts_with?(plaintext, "ma_")
      assert token.name == "claude-code"
      assert token.prefix == String.slice(plaintext, 0, 12)
      assert token.token_hash == :crypto.hash(:sha256, plaintext)
      refute token.revoked_at
      assert Repo.get!(ApiToken, token.id).token_hash != plaintext
    end

    test "requires a name" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.create_api_token(user, %{"name" => ""})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_api_tokens/1" do
    test "returns only the user's tokens, revoked included, newest first" do
      user = user_fixture()
      other = user_fixture()

      {:ok, _plaintext, first} = Accounts.create_api_token(user, %{"name" => "first"})
      {:ok, _plaintext, second} = Accounts.create_api_token(user, %{"name" => "second"})
      {:ok, _plaintext, _other} = Accounts.create_api_token(other, %{"name" => "not-mine"})
      {:ok, revoked} = Accounts.revoke_api_token(user, first.id)

      # inserted_at has second precision; force distinct order
      Repo.update_all(
        from(t in ApiToken, where: t.id == ^second.id),
        set: [inserted_at: DateTime.add(revoked.inserted_at, 60)]
      )

      assert [%{name: "second"}, %{name: "first", revoked_at: %DateTime{}}] =
               Accounts.list_api_tokens(user)
    end
  end

  describe "revoke_api_token/2" do
    test "revokes and is idempotent" do
      user = user_fixture()
      {:ok, _plaintext, token} = Accounts.create_api_token(user, %{"name" => "x"})

      assert {:ok, %ApiToken{revoked_at: %DateTime{} = at}} =
               Accounts.revoke_api_token(user, token.id)

      assert {:ok, %ApiToken{revoked_at: ^at}} = Accounts.revoke_api_token(user, token.id)
    end

    test "cannot revoke another user's token" do
      user = user_fixture()
      other = user_fixture()
      {:ok, _plaintext, token} = Accounts.create_api_token(other, %{"name" => "x"})

      assert {:error, :not_found} = Accounts.revoke_api_token(user, token.id)
    end
  end

  describe "verify_api_token/1" do
    test "returns the user for a valid token and touches last_used_at" do
      user = user_fixture()
      {:ok, plaintext, token} = Accounts.create_api_token(user, %{"name" => "x"})

      assert {:ok, verified} = Accounts.verify_api_token(plaintext)
      assert verified.id == user.id
      assert %DateTime{} = Repo.get!(ApiToken, token.id).last_used_at
    end

    test "throttles the last_used_at write" do
      user = user_fixture()
      {:ok, plaintext, token} = Accounts.create_api_token(user, %{"name" => "x"})

      assert {:ok, _user} = Accounts.verify_api_token(plaintext)
      first = Repo.get!(ApiToken, token.id).last_used_at
      assert {:ok, _user} = Accounts.verify_api_token(plaintext)
      assert Repo.get!(ApiToken, token.id).last_used_at == first
    end

    test "rejects revoked, unknown, and malformed tokens" do
      user = user_fixture()
      {:ok, plaintext, token} = Accounts.create_api_token(user, %{"name" => "x"})
      {:ok, _revoked} = Accounts.revoke_api_token(user, token.id)

      assert :error = Accounts.verify_api_token(plaintext)
      assert :error = Accounts.verify_api_token("ma_definitely-not-a-token")
      assert :error = Accounts.verify_api_token(nil)
    end
  end
end
