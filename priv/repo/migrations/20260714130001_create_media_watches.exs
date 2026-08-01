defmodule MediaAssist.Repo.Migrations.CreateMediaWatches do
  use Ecto.Migration

  def change do
    # One row per (user, title): the watch signal the recommender reads.
    create table(:media_watches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :item_id,
          references(:media_items, type: :binary_id, on_delete: :delete_all),
          null: false

      add :play_count, :integer, null: false, default: 1
      add :last_played_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_watches, [:user_id, :item_id])
    create index(:media_watches, [:item_id])
  end
end
