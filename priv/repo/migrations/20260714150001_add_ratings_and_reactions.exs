defmodule MediaAssist.Repo.Migrations.AddRatingsAndReactions do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      # Normalized external ratings from the arr metadata service:
      # %{"rt" => 88, "imdb" => 8.0, "metacritic" => 81, ...}
      add :ratings, :map, null: false, default: %{}
    end

    alter table(:media_watches) do
      # Emby reactions: heart, and nullable thumbs (nil = unset).
      add :favorite, :boolean, null: false, default: false
      add :liked, :boolean
    end
  end
end
