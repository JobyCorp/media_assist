defmodule MediaAssist.Integrations.IndexSettings do
  @moduledoc """
  Singleton row: what the media index caches from the arrstack and how
  often. `embed_on_sync` controls whether synced items are queued for
  embedding through the AI gateway.
  """

  use MediaAssist.Schema
  import Ecto.Changeset

  @intervals [60, 180, 360, 720, 1440]

  def intervals, do: @intervals

  schema "index_settings" do
    field :sync_movies, :boolean, default: true
    field :sync_series, :boolean, default: true
    field :sync_interval_minutes, :integer, default: 360
    field :embed_on_sync, :boolean, default: true
    field :last_synced_at, :utc_datetime

    timestamps()
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:sync_movies, :sync_series, :sync_interval_minutes, :embed_on_sync])
    |> validate_inclusion(:sync_interval_minutes, @intervals)
  end
end
