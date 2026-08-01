defmodule MediaAssist.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    # Bearer tokens for the MCP endpoint. Only the sha256 hash lands on
    # disk; `prefix` keeps the first characters of the plaintext so the
    # UI can identify a token without being able to reconstruct it.
    # Revocation sets `revoked_at` — rows are never deleted.
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :token_hash, :binary, null: false
      add :prefix, :string, null: false
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:api_tokens, [:user_id])
    create unique_index(:api_tokens, [:token_hash])
  end
end
