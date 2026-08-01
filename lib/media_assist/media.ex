defmodule MediaAssist.Media do
  @moduledoc """
  The media index: movies and series cached from the arrstack, stored as
  a vector-backed graph. Items carry pgvector embeddings; typed weighted
  edges hold relationships between items. The recommender combines both
  — embedding distance for "feels similar", edges for explicit structure
  (franchise, shared genre, watched-together).
  """

  import Ecto.Query, warn: false

  alias MediaAssist.Media.Edge
  alias MediaAssist.Media.Item
  alias MediaAssist.Media.Watch
  alias MediaAssist.Repo

  ## Items

  def list_items(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Item
    |> maybe_filter_kind(opts[:kind])
    |> order_by([i], asc: i.title)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, kind), do: where(query, [i], i.kind == ^kind)

  def get_item!(id), do: Repo.get!(Item, id)

  @doc """
  Fetches an item by id from URL params: returns `{:ok, item}` or
  `:error` for both malformed UUIDs and missing rows.
  """
  def fetch_item(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Item{} = item <- Repo.get(Item, uuid) do
      {:ok, item}
    else
      _not_found -> :error
    end
  end

  @default_per_page 48

  @doc """
  Filtered, paginated catalog search. Options: `:q` (title substring),
  `:kind`, `:genre`, `:presence` ("held" [default] | "all" | any status
  value), `:page`, `:per_page`. Returns
  `%{items: [...], total: n, page: p, pages: last_page}`.
  """
  def search_items(opts \\ []) do
    page = opts |> Keyword.get(:page, 1) |> max(1)
    per_page = Keyword.get(opts, :per_page, @default_per_page)

    base =
      Item
      |> filter_presence(Keyword.get(opts, :presence, "held"))
      |> maybe_filter_kind(blank_to_nil(opts[:kind]))
      |> maybe_filter_genre(blank_to_nil(opts[:genre]))
      |> maybe_filter_query(blank_to_nil(opts[:q]))

    total = Repo.aggregate(base, :count)
    pages = max(ceil(total / per_page), 1)
    page = min(page, pages)

    items =
      base
      |> order_by([i], asc: i.title, asc: i.year)
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> Repo.all()

    %{items: items, total: total, page: page, pages: pages}
  end

  @doc "Distinct genres across the index, sorted."
  def genres do
    Repo.all(from i in Item, select: fragment("DISTINCT unnest(?)", i.genres))
    |> Enum.sort()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp filter_presence(query, "all"), do: query
  defp filter_presence(query, "held"), do: where(query, [i], i.status in ~w(in_library missing))
  defp filter_presence(query, ""), do: filter_presence(query, "held")
  defp filter_presence(query, nil), do: filter_presence(query, "held")
  defp filter_presence(query, status), do: where(query, [i], i.status == ^status)

  defp maybe_filter_genre(query, nil), do: query

  defp maybe_filter_genre(query, genre),
    do: where(query, [i], fragment("? = ANY(?)", ^genre, i.genres))

  defp maybe_filter_query(query, nil), do: query

  defp maybe_filter_query(query, q) do
    escaped = Regex.replace(~r/[\\%_]/, q, fn match -> "\\" <> match end)
    where(query, [i], ilike(i.title, ^("%" <> escaped <> "%")))
  end

  def stats do
    counts =
      Repo.all(
        from i in Item,
          where: i.status in ~w(in_library missing),
          group_by: i.kind,
          select: {i.kind, count(i.id)}
      )
      |> Map.new()

    embedded = Repo.one(from i in Item, where: not is_nil(i.embedding), select: count(i.id))

    %{
      movies: Map.get(counts, "movie", 0),
      series: Map.get(counts, "series", 0),
      embedded: embedded
    }
  end

  @rating_sources %{
    "rottenTomatoes" => "rt",
    "imdb" => "imdb",
    "metacritic" => "metacritic",
    "tmdb" => "tmdb",
    "trakt" => "trakt"
  }

  @doc """
  Normalizes an arr ratings object to flat `%{"rt" => 88, ...}`. Radarr
  sends a map of sources; Sonarr sends a single `%{"value" => v}` which
  lands under `"community"`. Zero values (arr's "no data") are dropped.
  """
  def normalize_ratings(%{"value" => value}) when is_number(value) and value > 0,
    do: %{"community" => value}

  def normalize_ratings(%{} = ratings) do
    for {source, %{"value" => value}} <- ratings,
        key = @rating_sources[source],
        is_number(value) and value > 0,
        into: %{},
        do: {key, value}
  end

  def normalize_ratings(_none), do: %{}

  @doc """
  Inserts or updates a catalog item. Identity resolution: the arr key
  `(service, service_item_id)` first, then provider ids — so a `known`
  item later added to Radarr merges into its existing row (keeping its
  embedding, watches, and edges) instead of duplicating.
  """
  def upsert_item(attrs) do
    attrs = Map.new(attrs)

    case existing_item(attrs) do
      nil -> %Item{} |> Item.changeset(attrs) |> Repo.insert()
      item -> item |> Item.changeset(attrs) |> Repo.update()
    end
  end

  defp existing_item(attrs) do
    by_service_identity(attrs) ||
      find_item_by_provider_ids(attrs[:kind], %{
        tmdb: attrs[:tmdb_id],
        tvdb: attrs[:tvdb_id],
        imdb: attrs[:imdb_id]
      })
  end

  defp by_service_identity(%{service: service, service_item_id: service_item_id})
       when not is_nil(service_item_id),
       do: Repo.get_by(Item, service: service, service_item_id: service_item_id)

  defp by_service_identity(_attrs), do: nil

  @doc """
  Flips arr-synced items that vanished from the arr's response to
  `departed` — row, embedding, watches, and edges all survive; only
  presence changes. Callers must pass the full id set from a successful
  fetch (never call after a failed one).
  """
  def mark_departed(service, seen_service_item_ids) do
    now = DateTime.utc_now(:second)

    from(i in Item,
      where:
        i.service == ^service and i.status in ["in_library", "missing"] and
          i.service_item_id not in ^seen_service_item_ids
    )
    |> Repo.update_all(set: [status: "departed", departed_at: now, updated_at: now])
  end

  @held_statuses ~w(in_library missing)

  @doc """
  Provider ids of titles the arrs currently hold or monitor — the
  "can't request what you have" set. Departed/known titles are absent
  on purpose: re-acquiring them is legitimate.
  """
  def held_provider_ids(kind) do
    rows =
      Repo.all(
        from i in Item,
          where: i.kind == ^kind and i.status in @held_statuses,
          select: {i.tmdb_id, i.tvdb_id}
      )

    %{
      tmdb: MapSet.new(rows, &elem(&1, 0)),
      tvdb: MapSet.new(rows, &elem(&1, 1))
    }
  end

  def put_embedding(%Item{} = item, embedding) do
    item
    |> Ecto.Changeset.change(embedding: embedding)
    |> Repo.update()
  end

  @doc "Known/departed items without posters, for the import's metadata backfill."
  def list_items_missing_posters(kind, limit \\ 500) do
    Repo.all(
      from i in Item,
        where: i.kind == ^kind and is_nil(i.poster_url) and i.status in ["known", "departed"],
        limit: ^limit
    )
  end

  @doc "Oldest items still waiting for an embedding, for the embed job's batches."
  def list_unembedded_items(limit \\ 32) do
    Repo.all(
      from i in Item, where: is_nil(i.embedding), order_by: [asc: i.inserted_at], limit: ^limit
    )
  end

  @doc """
  The text an item is embedded from: title, year, kind, genres, and
  overview — the fields that carry "what this feels like".
  """
  def embedding_text(%Item{} = item) do
    [
      "#{item.title} (#{item.year || "year unknown"}) — #{item.kind}",
      item.genres != [] && "genres: " <> Enum.join(item.genres, ", "),
      item.overview
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  @doc "Items nearest to the given one by embedding cosine distance."
  def similar_items(%Item{} = item, opts \\ []) do
    item |> similar_items_with_distance(opts) |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Like `similar_items/2` but returns `{item, cosine_distance}` tuples.
  Pass `statuses:` to restrict candidates by presence (the recommender
  limits itself to `in_library` — recommendations you can watch tonight).
  """
  def similar_items_with_distance(%Item{id: id, embedding: embedding}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    if is_nil(embedding) do
      []
    else
      query =
        from i in Item,
          where: i.id != ^id and not is_nil(i.embedding),
          order_by: fragment("? <=> ?", i.embedding, ^embedding),
          limit: ^limit,
          select: {i, fragment("? <=> ?", i.embedding, ^embedding)}

      query =
        case opts[:statuses] do
          nil -> query
          statuses -> where(query, [i], i.status in ^statuses)
        end

      Repo.all(query)
    end
  end

  @doc """
  Items nearest to a raw query vector — the retrieval step for the
  assistant's library-aware answers.
  """
  def nearest_to_vector(vector, opts \\ []) when is_list(vector) do
    limit = Keyword.get(opts, :limit, 8)

    Repo.all(
      from i in Item,
        where: not is_nil(i.embedding),
        order_by: fragment("? <=> ?", i.embedding, ^Pgvector.new(vector)),
        limit: ^limit
    )
  end

  @doc "Most recently added titles (Radarr/Sonarr's own added dates)."
  def recently_added(limit \\ 8) do
    Repo.all(
      from i in Item,
        where: not is_nil(i.added_at),
        order_by: [desc: i.added_at],
        limit: ^limit
    )
  end

  @doc """
  Matches an Emby-style provider-id map to an index item. Movies match
  tmdb → imdb; series tvdb → tmdb → imdb (Radarr/Sonarr key differently).
  """
  def find_item_by_provider_ids(kind, ids) do
    keys =
      case kind do
        "movie" ->
          [tmdb_id: parse_int(ids[:tmdb]), imdb_id: ids[:imdb]]

        "series" ->
          [tvdb_id: parse_int(ids[:tvdb]), tmdb_id: parse_int(ids[:tmdb]), imdb_id: ids[:imdb]]
      end

    Enum.find_value(keys, fn
      {_field, nil} ->
        nil

      {field, value} ->
        Repo.one(from i in Item, where: i.kind == ^kind and field(i, ^field) == ^value, limit: 1)
    end)
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> nil
    end
  end

  ## Watches

  @doc "Idempotently records a user's watch state for an item."
  def upsert_watch(%MediaAssist.Accounts.User{id: user_id}, %Item{id: item_id}, attrs \\ %{}) do
    changeset =
      Watch.changeset(
        %Watch{},
        Map.merge(%{user_id: user_id, item_id: item_id}, Map.new(attrs))
      )

    Repo.insert(changeset,
      on_conflict: {:replace, [:play_count, :last_played_at, :favorite, :liked, :updated_at]},
      conflict_target: [:user_id, :item_id],
      returning: true
    )
  end

  @doc """
  Import-safe watch merge: unlike `upsert_watch/3` (which trusts its
  source), this never lowers play counts, never regresses recency, and
  never touches Emby's favorite/liked flags — so a Trakt import and the
  Emby sync can both write the same row without clobbering each other.
  """
  def merge_watch(%MediaAssist.Accounts.User{id: user_id}, %Item{id: item_id}, attrs) do
    attrs = Map.new(attrs)

    case Repo.get_by(Watch, user_id: user_id, item_id: item_id) do
      nil ->
        %Watch{}
        |> Watch.changeset(Map.merge(%{user_id: user_id, item_id: item_id}, attrs))
        |> Repo.insert()

      watch ->
        watch
        |> Watch.changeset(%{
          play_count: max(watch.play_count, attrs[:play_count] || 1),
          last_played_at: latest(watch.last_played_at, attrs[:last_played_at]),
          rating: attrs[:rating] || watch.rating
        })
        |> Repo.update()
    end
  end

  defp latest(nil, new), do: new
  defp latest(old, nil), do: old
  defp latest(old, new), do: if(DateTime.after?(new, old), do: new, else: old)

  @doc "Items a user has watched, most recently played first."
  def list_watched_items(%MediaAssist.Accounts.User{id: user_id}, opts \\ []) do
    Repo.all(
      from w in Watch,
        join: i in Item,
        on: i.id == w.item_id,
        where: w.user_id == ^user_id,
        order_by: [desc_nulls_last: w.last_played_at],
        limit: ^Keyword.get(opts, :limit, 50),
        select: {w, i}
    )
  end

  @doc "Who has watched an item, as `{watch, user}` tuples."
  def item_watchers(%Item{id: item_id}) do
    Repo.all(
      from w in Watch,
        join: u in MediaAssist.Accounts.User,
        on: u.id == w.user_id,
        where: w.item_id == ^item_id,
        order_by: [desc_nulls_last: w.last_played_at],
        select: {w, u}
    )
  end

  @doc "Every item id a user has watched — the recommender's exclusion set."
  def watched_item_ids(%MediaAssist.Accounts.User{id: user_id}) do
    Repo.all(from w in Watch, where: w.user_id == ^user_id, select: w.item_id)
  end

  @doc "The household's most recent watches, as `{watch, item, user}` tuples."
  def recent_watches(limit \\ 8) do
    Repo.all(
      from w in Watch,
        join: i in Item,
        on: i.id == w.item_id,
        join: u in MediaAssist.Accounts.User,
        on: u.id == w.user_id,
        where: not is_nil(w.last_played_at),
        order_by: [desc: w.last_played_at],
        limit: ^limit,
        select: {w, i, u}
    )
  end

  @doc "Watch counts: total watch rows and distinct watched items."
  def watch_stats do
    %{
      watches: Repo.aggregate(Watch, :count),
      watched_items: Repo.one(from w in Watch, select: count(w.item_id, :distinct))
    }
  end

  ## Graph edges

  @doc "Idempotently records a relationship; re-upserting updates the weight."
  def upsert_edge(%Item{id: from_id}, %Item{id: to_id}, relation, weight \\ 1.0) do
    changeset =
      Edge.changeset(%Edge{}, %{
        from_item_id: from_id,
        to_item_id: to_id,
        relation: relation,
        weight: weight
      })

    Repo.insert(changeset,
      on_conflict: {:replace, [:weight, :updated_at]},
      conflict_target: [:from_item_id, :to_item_id, :relation],
      returning: true
    )
  end

  def delete_edges(%Item{id: id}) do
    Repo.delete_all(from e in Edge, where: e.from_item_id == ^id or e.to_item_id == ^id)
  end

  @doc """
  Outgoing neighbors of an item, heaviest edges first. Pass `relation:`
  to walk one relation type. Returns `{edge, item}` tuples.
  """
  def neighbors(%Item{id: id}, opts \\ []) do
    query =
      from e in Edge,
        join: i in Item,
        on: i.id == e.to_item_id,
        where: e.from_item_id == ^id,
        order_by: [desc: e.weight],
        limit: ^Keyword.get(opts, :limit, 20),
        select: {e, i}

    query =
      case opts[:relation] do
        nil -> query
        relation -> where(query, [e], e.relation == ^relation)
      end

    Repo.all(query)
  end
end
