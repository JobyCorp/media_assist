defmodule MediaAssist.Repo.Migrations.TraktHistory do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Trakt profile to import watch history from (public profile).
      add :trakt_username, :string
    end

    alter table(:media_watches) do
      # Explicit 1–10 rating (from Trakt); strongest taste signal.
      add :rating, :integer
    end
  end
end
