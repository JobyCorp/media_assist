defmodule MediaAssist.Repo.Migrations.CreateIntegrations do
  use Ecto.Migration

  def change do
    # Singleton: how to reach the airo AI gateway
    create table(:gateway_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :base_url, :string
      add :token, :binary
      add :chat_model, :string, null: false, default: "chat"
      add :embedding_model, :string, null: false, default: "embed"
      add :enabled, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    # Arrstack services: radarr / sonarr / sabnzbd
    create table(:connections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :service, :string, null: false
      add :name, :string, null: false
      add :base_url, :string, null: false
      add :api_key, :binary, null: false
      add :enabled, :boolean, null: false, default: true
      add :status, :string, null: false, default: "unknown"
      add :last_checked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:connections, [:name])
    create index(:connections, [:service])

    # Singleton: what to cache into the media index and how often
    create table(:index_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sync_movies, :boolean, null: false, default: true
      add :sync_series, :boolean, null: false, default: true
      add :sync_interval_minutes, :integer, null: false, default: 360
      add :embed_on_sync, :boolean, null: false, default: true
      add :last_synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end
