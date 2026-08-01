defmodule MediaAssist.Media.RecommenderTest do
  use MediaAssist.DataCase, async: true

  import MediaAssist.AccountsFixtures

  alias MediaAssist.Media
  alias MediaAssist.Media.Recommender

  defp embedded_item(title, vector, attrs \\ %{}) do
    {:ok, item} =
      Media.upsert_item(
        Map.merge(
          %{
            kind: "movie",
            title: title,
            service: "radarr",
            service_item_id: System.unique_integer([:positive])
          },
          attrs
        )
      )

    {:ok, item} = Media.put_embedding(item, vector)
    item
  end

  test "recommends unwatched neighbors of recent watches, with reasons" do
    user = user_fixture()

    seed = embedded_item("Seed", [1.0, 0.0, 0.0])
    near = embedded_item("Near", [0.95, 0.05, 0.0])
    far = embedded_item("Far", [0.0, 0.0, 1.0])
    watched_neighbor = embedded_item("Already Seen", [0.9, 0.1, 0.0])

    {:ok, _} = Media.upsert_watch(user, seed, last_played_at: ~U[2026-07-01 20:00:00Z])

    {:ok, _} =
      Media.upsert_watch(user, watched_neighbor, last_played_at: ~U[2026-06-01 20:00:00Z])

    assert %{source: :watches, recommendations: recs} = Recommender.for_user(user)
    titles = Enum.map(recs, & &1.item.title)

    assert "Near" in titles
    refute "Seed" in titles
    refute "Already Seen" in titles

    near_rec = Enum.find(recs, &(&1.item.title == "Near"))
    assert near_rec.reason =~ "because you watched"
    assert near_rec.match in 0..100

    # Far is a valid candidate but must rank below Near
    assert Enum.find_index(titles, &(&1 == "Near")) < Enum.find_index(titles, &(&1 == "Far"))
  end

  test "favorite seeds upgrade the reason; thumbs-down seeds are excluded" do
    user = user_fixture()

    loved = embedded_item("Loved", [1.0, 0.0, 0.0])
    loved_neighbor = embedded_item("Loved Neighbor", [0.95, 0.05, 0.0])
    hated = embedded_item("Hated", [0.0, 1.0, 0.0])
    hated_neighbor = embedded_item("Hated Neighbor", [0.0, 0.95, 0.05])

    {:ok, _} =
      Media.upsert_watch(user, loved, favorite: true, last_played_at: ~U[2026-07-01 20:00:00Z])

    {:ok, _} =
      Media.upsert_watch(user, hated, liked: false, last_played_at: ~U[2026-07-02 20:00:00Z])

    assert %{recommendations: recs} = Recommender.for_user(user)
    titles = Enum.map(recs, & &1.item.title)

    loved_rec = Enum.find(recs, &(&1.item.title == "Loved Neighbor"))
    assert loved_rec.reason == "because you loved Loved"

    # The hated seed contributes nothing, so its close neighbor can only
    # appear via the loved seed's (distant) similarity — never as the top hit.
    refute List.first(titles) == "Hated Neighbor"
    refute Enum.any?(recs, &(&1.reason =~ "Hated"))
  end

  test "falls back to recently added for users without watches, and for nil" do
    {:ok, item} =
      Media.upsert_item(%{
        kind: "movie",
        title: "Fresh",
        service: "radarr",
        service_item_id: 1,
        added_at: ~U[2026-07-10 00:00:00Z]
      })

    assert %{source: :recently_added, recommendations: [rec]} =
             Recommender.for_user(user_fixture())

    assert rec.item.id == item.id
    assert rec.reason == "new in the library"
    assert rec.match == nil

    assert %{source: :recently_added} = Recommender.for_user(nil)
  end

  test "recently_added/1 orders by added_at and skips items without it" do
    {:ok, old} =
      Media.upsert_item(%{
        kind: "movie",
        title: "Old",
        service: "radarr",
        service_item_id: 1,
        added_at: ~U[2026-01-01 00:00:00Z]
      })

    {:ok, new} =
      Media.upsert_item(%{
        kind: "movie",
        title: "New",
        service: "radarr",
        service_item_id: 2,
        added_at: ~U[2026-07-01 00:00:00Z]
      })

    {:ok, _no_date} =
      Media.upsert_item(%{kind: "movie", title: "Undated", service: "radarr", service_item_id: 3})

    assert Media.recently_added(5) |> Enum.map(& &1.id) == [new.id, old.id]
  end
end
