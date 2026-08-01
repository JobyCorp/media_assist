defmodule MediaAssist.Media.Edge do
  @moduledoc """
  A typed, weighted edge between two media items — the relationship
  graph the recommender walks. Relations are open-ended strings
  (`"similar_to"`, `"same_franchise"`, `"shared_genre"`, ...); one
  relation per direction per pair.
  """

  use MediaAssist.Schema
  import Ecto.Changeset

  alias MediaAssist.Media.Item

  schema "media_edges" do
    belongs_to :from_item, Item
    belongs_to :to_item, Item
    field :relation, :string
    field :weight, :float, default: 1.0

    timestamps()
  end

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:from_item_id, :to_item_id, :relation, :weight])
    |> validate_required([:from_item_id, :to_item_id, :relation])
    |> validate_number(:weight, greater_than: 0)
    |> check_distinct_endpoints()
    |> unique_constraint([:from_item_id, :to_item_id, :relation])
  end

  defp check_distinct_endpoints(changeset) do
    if get_field(changeset, :from_item_id) == get_field(changeset, :to_item_id) do
      add_error(changeset, :to_item_id, "cannot link an item to itself")
    else
      changeset
    end
  end
end
