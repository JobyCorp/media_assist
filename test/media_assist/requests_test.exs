defmodule MediaAssist.RequestsTest do
  use MediaAssist.DataCase, async: true
  use Oban.Testing, repo: MediaAssist.Repo

  import MediaAssist.AccountsFixtures

  alias MediaAssist.Requests

  @movie %{kind: "movie", title: "Dark City", year: 1998, tmdb_id: 2666}

  test "create_request/2 inserts pending and enqueues the add worker" do
    user = user_fixture()

    assert {:ok, request} = Requests.create_request(user, @movie)
    assert request.status == "pending"

    assert_enqueued(
      worker: MediaAssist.Requests.AddWorker,
      args: %{"request_id" => request.id}
    )
  end

  test "duplicate provider ids are rejected" do
    user = user_fixture()
    {:ok, _} = Requests.create_request(user, @movie)

    assert {:error, changeset} = Requests.create_request(user_fixture(), @movie)
    assert %{kind: [_]} = errors_on(changeset)
  end

  test "kind-appropriate provider id is required" do
    user = user_fixture()

    assert {:error, changeset} =
             Requests.create_request(user, %{kind: "movie", title: "No Id"})

    assert %{tmdb_id: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Requests.create_request(user, %{kind: "series", title: "No Id", tmdb_id: 1})

    assert %{tvdb_id: [_]} = errors_on(changeset)
  end

  test "retry_request/1 re-queues only failed requests and broadcasts" do
    user = user_fixture()
    Requests.subscribe()
    {:ok, request} = Requests.create_request(user, @movie)
    assert_receive {:request_updated, %{status: "pending"}}

    assert {:error, {:not_failed, "pending"}} = Requests.retry_request(request)

    failed = Requests.mark_failed(request, "boom")
    assert_receive {:request_updated, %{status: "failed"}}

    assert {:ok, retried} = Requests.retry_request(failed)
    assert retried.status == "pending"
    assert_receive {:request_updated, %{status: "pending"}}
  end

  test "delete_request/1 removes the row" do
    user = user_fixture()
    {:ok, request} = Requests.create_request(user, @movie)

    assert {:ok, _} = Requests.delete_request(request)
    assert Requests.list_recent_requests() == []
  end

  test "status transitions and requested_provider_ids" do
    user = user_fixture()
    {:ok, movie_request} = Requests.create_request(user, @movie)

    {:ok, series_request} =
      Requests.create_request(user, %{kind: "series", title: "Dark", tvdb_id: 332_484})

    assert Requests.mark_added(movie_request).status == "added"
    assert Requests.mark_failed(series_request, "boom").error == "boom"

    ids = Requests.requested_provider_ids()
    assert MapSet.member?(ids.movie, 2666)
    assert MapSet.member?(ids.series, 332_484)

    assert [_first, _second] = Requests.list_recent_requests()
  end
end
