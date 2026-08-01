defmodule MediaAssist.Repo.Migrations.CreateMediaGraph do
  use Ecto.Migration

  def change do
    # Media cached from Radarr/Sonarr. `embedding` is dimensionless until
    # the embedding model is locked in — add a fixed dimension plus an
    # HNSW index when the embedder is chosen.
    create table(:media_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :title, :string, null: false
      add :year, :integer
      add :overview, :text
      add :genres, {:array, :string}, null: false, default: []
      add :tmdb_id, :integer
      add :tvdb_id, :integer
      add :imdb_id, :string
      add :service, :string, null: false
      add :service_item_id, :integer, null: false
      add :poster_url, :string
      add :status, :string, null: false, default: "in_library"
      add :embedding, :vector
      add :synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_items, [:service, :service_item_id])
    create index(:media_items, [:kind])
    create index(:media_items, [:tmdb_id])
    create index(:media_items, [:tvdb_id])

    # Typed, weighted edges between media items — the relationship graph
    # the recommender walks.
    create table(:media_edges, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :from_item_id,
          references(:media_items, type: :binary_id, on_delete: :delete_all),
          null: false

      add :to_item_id,
          references(:media_items, type: :binary_id, on_delete: :delete_all),
          null: false

      add :relation, :string, null: false
      add :weight, :float, null: false, default: 1.0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_edges, [:from_item_id, :to_item_id, :relation])
    create index(:media_edges, [:to_item_id])
  end
end
