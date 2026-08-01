defmodule MediaAssist.Media.Item do
  @moduledoc """
  One title in the catalog — everything the system knows about, whether
  held or not. Presence is the `status` field:

    * `in_library` — file on disk (from the arrs)
    * `missing`    — monitored by an arr, no file yet
    * `departed`   — was in the library, since deleted (`departed_at`)
    * `known`      — seen/known but never held (e.g. Trakt history)

  `embedding` is the item's vector; arr-held rows key back to their arr
  via `(service, service_item_id)`, while `known` rows carry only
  provider ids (`service` names the source, e.g. "trakt").
  """

  use MediaAssist.Schema
  import Ecto.Changeset

  @kinds ~w(movie series)
  @statuses ~w(in_library missing departed known)

  def statuses, do: @statuses

  schema "media_items" do
    field :kind, :string
    field :title, :string
    field :year, :integer
    field :overview, :string
    field :genres, {:array, :string}, default: []
    field :tmdb_id, :integer
    field :tvdb_id, :integer
    field :imdb_id, :string
    field :service, :string
    field :service_item_id, :integer
    field :poster_url, :string
    field :status, :string, default: "in_library"
    field :ratings, :map, default: %{}
    field :embedding, Pgvector.Ecto.Vector
    field :departed_at, :utc_datetime
    field :added_at, :utc_datetime
    field :synced_at, :utc_datetime

    timestamps()
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :kind,
      :title,
      :year,
      :overview,
      :genres,
      :tmdb_id,
      :tvdb_id,
      :imdb_id,
      :service,
      :service_item_id,
      :poster_url,
      :status,
      :ratings,
      :departed_at,
      :added_at,
      :synced_at
    ])
    |> validate_required([:kind, :title, :service])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_identity()
    |> unique_constraint([:service, :service_item_id])
    |> unique_constraint([:kind, :tmdb_id], name: :media_items_kind_tmdb_id_index)
    |> unique_constraint([:kind, :tvdb_id], name: :media_items_kind_tvdb_id_index)
  end

  # Every row needs a resolvable identity: an arr id or a provider id.
  defp validate_identity(changeset) do
    identity =
      [:service_item_id, :tmdb_id, :tvdb_id, :imdb_id]
      |> Enum.any?(&get_field(changeset, &1))

    if identity do
      changeset
    else
      add_error(changeset, :service_item_id, "an arr id or provider id is required")
    end
  end
end
