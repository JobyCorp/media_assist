defmodule MediaAssist.Requests do
  @moduledoc """
  Household requests for new titles. v1 is auto-approved: creating a
  request enqueues `Requests.AddWorker`, which pushes the title to the
  right arr with default quality profile and root folder. The `requests`
  table is the durable record the future requests page builds on.
  """

  import Ecto.Query, warn: false

  alias MediaAssist.Accounts.User
  alias MediaAssist.Repo
  alias MediaAssist.Requests.Request

  @topic "requests"

  @doc "Subscribe to request lifecycle events: `{:request_updated, request}`."
  def subscribe, do: Phoenix.PubSub.subscribe(MediaAssist.PubSub, @topic)

  defp broadcast(request) do
    Phoenix.PubSub.broadcast(MediaAssist.PubSub, @topic, {:request_updated, request})
    request
  end

  @doc """
  Creates a request from a discovery candidate and queues the add.
  Returns `{:ok, request}` or `{:error, changeset}` (duplicates surface
  as a unique error on the provider id).
  """
  def create_request(%User{} = user, attrs) do
    changeset = Request.changeset(%Request{}, Map.put(Map.new(attrs), :user_id, user.id))

    with {:ok, request} <- Repo.insert(changeset) do
      {:ok, _job} =
        Oban.insert(MediaAssist.Requests.AddWorker.new(%{"request_id" => request.id}))

      {:ok, broadcast(request)}
    end
  end

  @doc "Re-queues a failed request; status returns to pending."
  def retry_request(%Request{status: "failed"} = request) do
    request = Repo.update!(Request.status_changeset(request, "pending"))

    {:ok, _job} = Oban.insert(MediaAssist.Requests.AddWorker.new(%{"request_id" => request.id}))
    {:ok, broadcast(request)}
  end

  def retry_request(%Request{} = request), do: {:error, {:not_failed, request.status}}

  @doc """
  Deletes a request row. Doesn't undo an arr add — removing added
  titles is library management, not request management.
  """
  def delete_request(%Request{} = request) do
    with {:ok, deleted} <- Repo.delete(request) do
      {:ok, broadcast(deleted)}
    end
  end

  def get_request!(id), do: Repo.get!(Request, id)

  def list_recent_requests(limit \\ 20) do
    Repo.all(
      from r in Request,
        order_by: [desc: r.inserted_at],
        limit: ^limit,
        preload: [:user]
    )
  end

  @doc "Whether a catalog item already has a request, by provider id."
  def existing_for_item?(%{kind: "movie", tmdb_id: tmdb_id}) when not is_nil(tmdb_id),
    do: Repo.exists?(from r in Request, where: r.kind == "movie" and r.tmdb_id == ^tmdb_id)

  def existing_for_item?(%{kind: "series", tvdb_id: tvdb_id}) when not is_nil(tvdb_id),
    do: Repo.exists?(from r in Request, where: r.kind == "series" and r.tvdb_id == ^tvdb_id)

  def existing_for_item?(_item), do: false

  @doc "Provider ids already requested, for marking discovery candidates."
  def requested_provider_ids do
    movie_ids =
      Repo.all(
        from r in Request, where: r.kind == "movie" and not is_nil(r.tmdb_id), select: r.tmdb_id
      )

    series_ids =
      Repo.all(
        from r in Request, where: r.kind == "series" and not is_nil(r.tvdb_id), select: r.tvdb_id
      )

    %{movie: MapSet.new(movie_ids), series: MapSet.new(series_ids)}
  end

  def mark_added(%Request{} = request),
    do: request |> Request.status_changeset("added") |> Repo.update!() |> broadcast()

  def mark_failed(%Request{} = request, error),
    do: request |> Request.status_changeset("failed", error) |> Repo.update!() |> broadcast()
end
