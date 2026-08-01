defmodule MediaAssist.Repo.Migrations.CreateRequests do
  use Ecto.Migration

  def change do
    # A household member asking for a title. v1 auto-approves: the add
    # worker pushes straight to Radarr/Sonarr; the future requests page
    # inherits this table for visibility/approval.
    create table(:requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :kind, :string, null: false
      add :title, :string, null: false
      add :year, :integer
      add :tmdb_id, :integer
      add :tvdb_id, :integer
      add :poster_url, :string
      add :status, :string, null: false, default: "pending"
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:requests, [:user_id])
    create index(:requests, [:status])
    create unique_index(:requests, [:kind, :tmdb_id], where: "tmdb_id IS NOT NULL")
    create unique_index(:requests, [:kind, :tvdb_id], where: "tvdb_id IS NOT NULL")
  end
end
