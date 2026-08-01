defmodule MediaAssist.Accounts.ApiToken do
  @moduledoc """
  A long-lived bearer token for the MCP endpoint, acting as its owning
  user. Only the sha256 hash is stored — the plaintext (`ma_…`) exists
  exactly once, at creation, on its way to the clipboard. `prefix` keeps
  the first characters so the UI can identify a token without being able
  to reconstruct it. No expiry: lifecycle is revoke-only (`revoked_at`),
  and rows are never deleted.
  """

  use MediaAssist.Schema
  import Ecto.Changeset

  alias MediaAssist.Accounts.ApiToken

  @rand_size 32
  @prefix_length 12

  schema "api_tokens" do
    belongs_to :user, MediaAssist.Accounts.User

    field :name, :string
    field :token_hash, :binary
    field :prefix, :string
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps()
  end

  @doc """
  Builds the plaintext token and the changeset that stores its hash.

  Returns `{plaintext, changeset}` — the plaintext is never persisted,
  same contract as `UserToken.build_hashed_token/3`.
  """
  def build(user_id, attrs) do
    plaintext = "ma_" <> Base.url_encode64(:crypto.strong_rand_bytes(@rand_size), padding: false)

    changeset =
      %ApiToken{
        user_id: user_id,
        token_hash: :crypto.hash(:sha256, plaintext),
        prefix: String.slice(plaintext, 0, @prefix_length)
      }
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> validate_length(:name, max: 80)

    {plaintext, changeset}
  end

  def hash(plaintext) when is_binary(plaintext), do: :crypto.hash(:sha256, plaintext)

  def revoked?(%ApiToken{revoked_at: nil}), do: false
  def revoked?(%ApiToken{}), do: true
end
