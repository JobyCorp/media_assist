defmodule MediaAssist.Media.Watch do
  @moduledoc """
  One user's watch state for one media item, synced from Emby. The
  per-user taste signal the recommender reads alongside embeddings and
  graph edges.
  """

  use MediaAssist.Schema
  import Ecto.Changeset

  schema "media_watches" do
    belongs_to :user, MediaAssist.Accounts.User
    belongs_to :item, MediaAssist.Media.Item
    field :play_count, :integer, default: 1
    field :last_played_at, :utc_datetime
    field :favorite, :boolean, default: false
    field :liked, :boolean
    field :rating, :integer

    timestamps()
  end

  def changeset(watch, attrs) do
    watch
    |> cast(attrs, [:user_id, :item_id, :play_count, :last_played_at, :favorite, :liked, :rating])
    |> validate_required([:user_id, :item_id])
    |> validate_number(:play_count, greater_than: 0)
    |> validate_inclusion(:rating, 1..10)
    |> unique_constraint([:user_id, :item_id])
  end
end
