defmodule MediaAssist.Repo.Migrations.AddAddedAtToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      # When the title landed in Radarr/Sonarr — drives "recently added".
      add :added_at, :utc_datetime
    end

    create index(:media_items, [:added_at])
  end
end
