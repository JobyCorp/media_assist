defmodule MediaAssist.Requests.Request do
  @moduledoc """
  One household member's ask for a new title. Carries a metadata
  snapshot (title/year/ids/poster) so the request stays renderable even
  before the title exists in any index. Status walks
  `pending → added | failed`; approval states slot in here later.
  """

  use MediaAssist.Schema
  import Ecto.Changeset

  @statuses ~w(pending added failed)

  schema "requests" do
    belongs_to :user, MediaAssist.Accounts.User
    field :kind, :string
    field :title, :string
    field :year, :integer
    field :tmdb_id, :integer
    field :tvdb_id, :integer
    field :poster_url, :string
    field :status, :string, default: "pending"
    field :error, :string

    timestamps()
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:user_id, :kind, :title, :year, :tmdb_id, :tvdb_id, :poster_url])
    |> validate_required([:user_id, :kind, :title])
    |> validate_inclusion(:kind, ~w(movie series))
    |> validate_provider_id()
    |> unique_constraint([:kind, :tmdb_id])
    |> unique_constraint([:kind, :tvdb_id])
  end

  defp validate_provider_id(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :tmdb_id),
          get_field(changeset, :tvdb_id)} do
      {"movie", nil, _} -> add_error(changeset, :tmdb_id, "is required to add a movie")
      {"series", _, nil} -> add_error(changeset, :tvdb_id, "is required to add a series")
      _ok -> changeset
    end
  end

  def status_changeset(request, status, error \\ nil) when status in @statuses do
    change(request, status: status, error: error && String.slice(error, 0, 250))
  end
end
