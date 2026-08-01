defmodule MediaAssist.Repo.Migrations.AddEmbyUserMappingToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Emby user ids are GUID strings; the name is cached for display.
      # No unique index — household members may share an Emby profile.
      add :emby_user_id, :string
      add :emby_user_name, :string
    end
  end
end
