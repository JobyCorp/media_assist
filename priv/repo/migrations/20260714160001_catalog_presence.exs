defmodule MediaAssist.Repo.Migrations.CatalogPresence do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      # `known` items (seen but never held, e.g. Trakt history) have no
      # arr row; their service names the source ("trakt", "manual").
      modify :service_item_id, :integer, null: true, from: {:integer, null: false}
      # When a title left the library (status flipped to departed).
      add :departed_at, :utc_datetime
    end

    # One catalog row per real-world title: provider-id identity holds
    # across presence changes (a known item later added to Radarr merges
    # into the same row).
    create unique_index(:media_items, [:kind, :tmdb_id],
             where: "tmdb_id IS NOT NULL",
             name: :media_items_kind_tmdb_id_index
           )

    create unique_index(:media_items, [:kind, :tvdb_id],
             where: "tvdb_id IS NOT NULL",
             name: :media_items_kind_tvdb_id_index
           )

    create index(:media_items, [:status])
  end
end
