defmodule MediaAssist.Integrations.Connection do
  @moduledoc """
  One backend service the app talks to: Radarr, Sonarr, SABnzbd, Emby
  (the watch-history source), or TMDB (TV discovery lists). Identified
  by a household-friendly name; the API key is encrypted at rest.
  `status` reflects the last connectivity check.
  """

  use MediaAssist.Schema
  import Ecto.Changeset

  @services ~w(radarr sonarr sabnzbd emby tmdb trakt)
  @statuses ~w(unknown ok error)

  def services, do: @services

  schema "connections" do
    field :service, :string
    field :name, :string
    field :base_url, :string
    field :api_key, MediaAssist.Encrypted.Binary, redact: true
    field :enabled, :boolean, default: true
    field :status, :string, default: "unknown"
    field :last_checked_at, :utc_datetime

    timestamps()
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:service, :name, :base_url, :api_key, :enabled])
    |> validate_required([:service, :name, :base_url, :api_key])
    |> validate_inclusion(:service, @services)
    |> validate_length(:name, max: 60)
    |> validate_format(:base_url, ~r{^https?://\S+$},
      message: "must be an http(s) URL, e.g. http://192.168.1.20:7878"
    )
    |> unique_constraint(:name)
  end

  def status_changeset(connection, status) when status in @statuses do
    change(connection, status: status, last_checked_at: DateTime.utc_now(:second))
  end
end
