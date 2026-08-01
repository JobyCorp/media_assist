defmodule MediaAssist.MediaTest do
  use MediaAssist.DataCase, async: true

  alias MediaAssist.Media
  alias MediaAssist.Media.Item

  defp item_fixture(attrs \\ %{}) do
    defaults = %{
      kind: "movie",
      title: "Blade Runner 2049",
      year: 2017,
      service: "radarr",
      service_item_id: System.unique_integer([:positive])
    }

    {:ok, item} = Media.upsert_item(Map.merge(defaults, attrs))
    item
  end

  describe "items" do
    test "upsert_item/1 inserts, then updates on the same service identity" do
      item = item_fixture(%{service_item_id: 7, status: "missing"})

      {:ok, updated} =
        Media.upsert_item(%{
          kind: "movie",
          title: "Blade Runner 2049",
          service: "radarr",
          service_item_id: 7,
          status: "in_library"
        })

      assert updated.id == item.id
      assert updated.status == "in_library"
      assert MediaAssist.Repo.aggregate(Item, :count) == 1
    end

    test "upsert_item/1 preserves an existing embedding" do
      item = item_fixture(%{service_item_id: 8})
      {:ok, item} = Media.put_embedding(item, [1.0, 0.0, 0.0])

      {:ok, updated} =
        Media.upsert_item(%{
          kind: "movie",
          title: "Blade Runner 2049 (refresh)",
          service: "radarr",
          service_item_id: 8
        })

      assert updated.id == item.id
      assert Media.get_item!(item.id).embedding
    end

    test "stats/0 counts by kind and embedded" do
      item_fixture(%{kind: "movie"})
      item_fixture(%{kind: "series", title: "Severance"})
      {:ok, _} = Media.put_embedding(item_fixture(%{title: "Dark"}), [0.5, 0.5])

      assert %{movies: 2, series: 1, embedded: 1} = Media.stats()
    end

    test "similar_items/2 orders by cosine distance" do
      {:ok, a} = Media.put_embedding(item_fixture(%{title: "A"}), [1.0, 0.0])
      {:ok, near} = Media.put_embedding(item_fixture(%{title: "Near"}), [0.9, 0.1])
      {:ok, far} = Media.put_embedding(item_fixture(%{title: "Far"}), [0.0, 1.0])
      _no_embedding = item_fixture(%{title: "Unembedded"})

      assert [first, second] = Media.similar_items(a)
      assert first.id == near.id
      assert second.id == far.id
    end

    test "similar_items/2 returns [] for an unembedded item" do
      assert Media.similar_items(item_fixture()) == []
    end

    test "list_unembedded_items/1 returns only items without embeddings" do
      waiting = item_fixture(%{title: "Waiting"})
      {:ok, _} = Media.put_embedding(item_fixture(%{title: "Done"}), [1.0, 0.0])

      assert [%{id: id}] = Media.list_unembedded_items()
      assert id == waiting.id
    end

    test "embedding_text/1 composes title, genres, and overview, skipping blanks" do
      full =
        item_fixture(%{
          title: "Coherence",
          year: 2013,
          genres: ["Science Fiction", "Thriller"],
          overview: "Strange things happen at a dinner party."
        })

      assert Media.embedding_text(full) ==
               "Coherence (2013) — movie\ngenres: Science Fiction, Thriller\nStrange things happen at a dinner party."

      bare = item_fixture(%{title: "Bare", year: nil, genres: []})
      assert Media.embedding_text(bare) == "Bare (year unknown) — movie"
    end
  end

  describe "library search" do
    setup do
      item_fixture(%{title: "Blade Runner", year: 1982, genres: ["Science Fiction"]})
      item_fixture(%{title: "Blade Runner 2049", year: 2017, genres: ["Science Fiction"]})
      item_fixture(%{title: "Severance", kind: "series", genres: ["Drama", "Mystery"]})
      :ok
    end

    test "search_items/1 filters by title substring, kind, and genre" do
      assert %{total: 3} = Media.search_items()
      assert %{total: 2, items: [%{year: 1982}, %{year: 2017}]} = Media.search_items(q: "blade")
      assert %{total: 1, items: [%{title: "Severance"}]} = Media.search_items(kind: "series")
      assert %{total: 2} = Media.search_items(genre: "Science Fiction")
      assert %{total: 0} = Media.search_items(q: "blade", kind: "series")
    end

    test "search_items/1 escapes ilike wildcards" do
      assert %{total: 0} = Media.search_items(q: "%")
      assert %{total: 0} = Media.search_items(q: "_lade")
    end

    test "search_items/1 paginates and clamps the page" do
      assert %{items: [first], page: 1, pages: 3} = Media.search_items(per_page: 1)
      assert %{items: [second], page: 2} = Media.search_items(per_page: 1, page: 2)
      refute first.id == second.id
      assert %{page: 3} = Media.search_items(per_page: 1, page: 99)
      assert %{page: 1, pages: 1} = Media.search_items(q: "no-such-title", page: 5)
    end

    test "genres/0 returns sorted distinct genres" do
      assert Media.genres() == ["Drama", "Mystery", "Science Fiction"]
    end

    test "fetch_item/1 handles hits, misses, and malformed ids" do
      item = item_fixture(%{title: "Coherence"})

      assert {:ok, %{title: _}} = Media.fetch_item(item.id)
      assert :error = Media.fetch_item(Ecto.UUID.generate())
      assert :error = Media.fetch_item("not-a-uuid")
    end
  end

  describe "catalog presence" do
    test "upsert_item/1 merges a known item into an arr row by provider id" do
      {:ok, known} =
        Media.upsert_item(%{
          kind: "movie",
          title: "Seen on Trakt",
          service: "trakt",
          tmdb_id: 555,
          status: "known"
        })

      {:ok, embedded} = Media.put_embedding(known, [1.0, 0.0])

      {:ok, merged} =
        Media.upsert_item(%{
          kind: "movie",
          title: "Seen on Trakt",
          service: "radarr",
          service_item_id: 42,
          tmdb_id: 555,
          status: "in_library"
        })

      assert merged.id == embedded.id
      assert merged.status == "in_library"
      assert merged.service == "radarr"
      assert Media.get_item!(merged.id).embedding
      assert MediaAssist.Repo.aggregate(Media.Item, :count) == 1
    end

    test "items need some identity" do
      assert {:error, changeset} =
               Media.upsert_item(%{kind: "movie", title: "Ghost", service: "manual"})

      assert %{service_item_id: [_]} = errors_on(changeset)
    end

    test "mark_departed/2 flips only unseen held items" do
      keep = item_fixture(%{title: "Keep", service_item_id: 1})
      gone = item_fixture(%{title: "Gone", service_item_id: 2})

      {:ok, known} =
        Media.upsert_item(%{
          kind: "movie",
          title: "History",
          service: "trakt",
          tmdb_id: 777,
          status: "known"
        })

      assert {1, _} = Media.mark_departed("radarr", [keep.service_item_id])

      assert Media.get_item!(gone.id).status == "departed"
      assert Media.get_item!(gone.id).departed_at
      assert Media.get_item!(keep.id).status == "in_library"
      assert Media.get_item!(known.id).status == "known"
    end

    test "held_provider_ids/1 excludes departed and known" do
      held = item_fixture(%{title: "Held", tmdb_id: 1})
      departed = item_fixture(%{title: "Departed", tmdb_id: 2})
      {1, _} = Media.mark_departed("radarr", [held.service_item_id])

      {:ok, _} =
        Media.upsert_item(%{
          kind: "movie",
          title: "Known",
          service: "trakt",
          tmdb_id: 3,
          status: "known"
        })

      held = Media.held_provider_ids("movie")
      assert MapSet.member?(held.tmdb, 1)
      refute MapSet.member?(held.tmdb, departed.tmdb_id)
      refute MapSet.member?(held.tmdb, 3)
    end

    test "search_items/1 presence filtering" do
      item_fixture(%{title: "Held Movie", tmdb_id: 10})

      {:ok, _} =
        Media.upsert_item(%{
          kind: "movie",
          title: "Known Movie",
          service: "trakt",
          tmdb_id: 11,
          status: "known"
        })

      assert %{total: 1, items: [%{title: "Held Movie"}]} = Media.search_items()
      assert %{total: 2} = Media.search_items(presence: "all")
      assert %{total: 1, items: [%{title: "Known Movie"}]} = Media.search_items(presence: "known")
    end
  end

  describe "watches" do
    import MediaAssist.AccountsFixtures

    test "normalize_ratings/1 flattens radarr maps, sonarr values, drops zeros" do
      radarr = %{
        "rottenTomatoes" => %{"type" => "user", "value" => 88, "votes" => 0},
        "imdb" => %{"value" => 8.0, "votes" => 758_785},
        "metacritic" => %{"value" => 0, "votes" => 0},
        "unknown" => %{"value" => 5}
      }

      assert Media.normalize_ratings(radarr) == %{"rt" => 88, "imdb" => 8.0}
      assert Media.normalize_ratings(%{"value" => 8.5, "votes" => 100}) == %{"community" => 8.5}
      assert Media.normalize_ratings(nil) == %{}
      assert Media.normalize_ratings(%{}) == %{}
    end

    test "upsert_watch/3 carries favorite and liked through conflicts" do
      import MediaAssist.AccountsFixtures
      user = user_fixture()
      item = item_fixture()

      {:ok, _} = Media.upsert_watch(user, item)
      {:ok, updated} = Media.upsert_watch(user, item, favorite: true, liked: false)

      assert updated.favorite
      assert updated.liked == false
    end

    test "upsert_watch/3 is idempotent per (user, item) and updates play data" do
      user = user_fixture()
      item = item_fixture()

      assert {:ok, watch} = Media.upsert_watch(user, item)
      assert watch.play_count == 1

      assert {:ok, updated} =
               Media.upsert_watch(user, item,
                 play_count: 3,
                 last_played_at: ~U[2026-07-01 20:00:00Z]
               )

      assert updated.id == watch.id
      assert updated.play_count == 3
      assert MediaAssist.Repo.aggregate(Media.Watch, :count) == 1
    end

    test "merge_watch/3 ratchets play data and never clobbers emby flags" do
      user = user_fixture()
      item = item_fixture()

      # Emby got here first: hearted, 3 plays, recent
      {:ok, _} =
        Media.upsert_watch(user, item,
          play_count: 3,
          favorite: true,
          last_played_at: ~U[2026-07-01 20:00:00Z]
        )

      # Trakt import: more lifetime plays, older last-watched, a rating
      {:ok, merged} =
        Media.merge_watch(user, item,
          play_count: 7,
          last_played_at: ~U[2024-01-01 20:00:00Z],
          rating: 9
        )

      assert merged.play_count == 7
      assert merged.last_played_at == ~U[2026-07-01 20:00:00Z]
      assert merged.rating == 9
      assert merged.favorite

      # A second import with lower numbers changes nothing
      {:ok, again} = Media.merge_watch(user, item, play_count: 2, rating: nil)
      assert again.play_count == 7
      assert again.rating == 9

      # And a fresh merge creates the row outright
      other = item_fixture(%{title: "Fresh"})
      {:ok, fresh} = Media.merge_watch(user, other, play_count: 1, rating: 6)
      assert fresh.rating == 6
    end

    test "list_watched_items/2 and item_watchers/1 join through correctly" do
      user = user_fixture()
      other = user_fixture()
      item = item_fixture(%{title: "Coherence"})
      unwatched = item_fixture(%{title: "Unwatched"})

      {:ok, _} = Media.upsert_watch(user, item, last_played_at: ~U[2026-07-01 20:00:00Z])
      {:ok, _} = Media.upsert_watch(other, item)

      assert [{%{user_id: _}, %{title: "Coherence"}}] = Media.list_watched_items(user)
      assert Media.list_watched_items(user) |> length() == 1
      assert Media.item_watchers(item) |> length() == 2
      assert Media.item_watchers(unwatched) == []
      assert %{watches: 2, watched_items: 1} = Media.watch_stats()
    end

    test "find_item_by_provider_ids/2 matches by kind-appropriate keys" do
      movie = item_fixture(%{title: "Movie", tmdb_id: 78, imdb_id: "tt0083658"})
      series = item_fixture(%{title: "Series", kind: "series", tvdb_id: 371_980})

      assert %{id: id} = Media.find_item_by_provider_ids("movie", %{tmdb: "78"})
      assert id == movie.id

      assert %{id: id} = Media.find_item_by_provider_ids("movie", %{tmdb: nil, imdb: "tt0083658"})
      assert id == movie.id

      assert %{id: id} = Media.find_item_by_provider_ids("series", %{tvdb: 371_980})
      assert id == series.id

      # A series tmdb id must not match a movie row
      refute Media.find_item_by_provider_ids("series", %{tmdb: "78"})
      refute Media.find_item_by_provider_ids("movie", %{tmdb: "999999"})
      refute Media.find_item_by_provider_ids("movie", %{tmdb: "not-a-number"})
    end
  end

  describe "graph edges" do
    test "upsert_edge/4 is idempotent per relation and updates weight" do
      a = item_fixture(%{title: "A"})
      b = item_fixture(%{title: "B"})

      assert {:ok, edge} = Media.upsert_edge(a, b, "similar_to", 0.5)
      assert {:ok, updated} = Media.upsert_edge(a, b, "similar_to", 0.9)
      assert updated.id == edge.id
      assert updated.weight == 0.9

      assert {:ok, other} = Media.upsert_edge(a, b, "same_franchise")
      refute other.id == edge.id
    end

    test "rejects self-edges" do
      a = item_fixture(%{title: "A"})
      assert {:error, changeset} = Media.upsert_edge(a, a, "similar_to")
      assert %{to_item_id: [_]} = errors_on(changeset)
    end

    test "neighbors/2 walks outgoing edges heaviest-first, filtered by relation" do
      a = item_fixture(%{title: "A"})
      b = item_fixture(%{title: "B"})
      c = item_fixture(%{title: "C"})

      {:ok, _} = Media.upsert_edge(a, b, "similar_to", 0.4)
      {:ok, _} = Media.upsert_edge(a, c, "similar_to", 0.8)
      {:ok, _} = Media.upsert_edge(a, b, "same_franchise", 1.0)
      {:ok, _} = Media.upsert_edge(b, a, "similar_to", 1.0)

      assert [{%{weight: 1.0}, %{title: "B"}}, {_, %{title: "C"}}, {_, %{title: "B"}}] =
               Media.neighbors(a)

      assert [{_, %{title: "C"}}, {_, %{title: "B"}}] = Media.neighbors(a, relation: "similar_to")
    end

    test "deleting an item cascades its edges" do
      a = item_fixture(%{title: "A"})
      b = item_fixture(%{title: "B"})
      {:ok, _} = Media.upsert_edge(a, b, "similar_to")

      MediaAssist.Repo.delete!(b)
      assert Media.neighbors(a) == []
    end
  end
end
