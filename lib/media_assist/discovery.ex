defmodule MediaAssist.Discovery do
  @moduledoc """
  Finding media that is NOT in the library. The pipeline:

      seed/query → generate candidates → resolve via arr lookup
                 → dedupe against the index → score in our embedding space

  Candidate generation (v1) runs two sources: the gateway's chat model
  proposing titles for "like X" queries, and direct arr lookup for the
  free-text term itself. SearXNG slots in as a third source later.

  Resolution is the hallucination filter — an LLM title that the arr's
  metadata service can't find is dropped. Scoring embeds each
  candidate's metadata at query time and takes cosine similarity against
  the seed item's stored vector (or the embedded query text), so every
  candidate gets the same 0–100 match meter as the feed regardless of
  which source proposed it. Candidates are ephemeral — nothing persists
  until a title is requested.
  """

  require Logger

  alias MediaAssist.AI.Gateway
  alias MediaAssist.Integrations
  alias MediaAssist.Integrations.ArrClient
  alias MediaAssist.Media
  alias MediaAssist.Media.Item

  @llm_suggestions 15
  @lookup_take 5
  @max_results 18
  @shelf_size 12
  @new_release_window_days 180

  @doc """
  The instant browse shelves for the discover page, per kind. No LLM,
  no embedding — shelves are unscored by design, for speed, and always
  filtered to titles not in the library.

  Movies come from Radarr's Discover feed (one arr call):
  `%{new_releases, trending, popular, recommended}`.

  Series prefer a `trakt` connection (`%{trending, watched, popular}` —
  Trakt shows carry tvdb ids directly), falling back to `tmdb`
  (`%{airing, trending, popular}`; tvdb resolved at request time via
  `resolve_tvdb/1`).
  """
  def browse(kind \\ "movie")

  def browse("series") do
    trakt = Integrations.list_connections("trakt") |> List.first()
    tmdb = Integrations.list_connections("tmdb") |> List.first()

    cond do
      trakt ->
        trakt_tv_shelves(trakt)

      tmdb ->
        tmdb_tv_shelves(tmdb)

      true ->
        {:error, "no trakt or tmdb connection — add one in settings/connections for TV shelves"}
    end
  end

  def browse("movie") do
    case connection_for("movie") do
      nil ->
        {:error, "no radarr connection configured"}

      radarr ->
        movie_shelves(radarr, Integrations.list_connections("trakt") |> List.first())
    end
  end

  # Hybrid movie shelves: Radarr's feed provides new-releases and the
  # library-personalized recommendations; when a trakt connection
  # exists, its play-based trending/most-watched replace TMDB's
  # buzz-based trending/popular.
  defp movie_shelves(radarr, trakt) do
    sources =
      [{:radarr, fn -> ArrClient.discover_movies(radarr) end}] ++
        if trakt do
          [
            {:trakt_trending, fn -> ArrClient.fetch_trakt_movies(trakt, :trending) end},
            {:trakt_watched, fn -> ArrClient.fetch_trakt_movies(trakt, :watched) end}
          ]
        else
          []
        end

    results =
      sources
      |> Task.async_stream(fn {key, fetch} -> {key, fetch.()} end,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {key, {:ok, list}}}, acc -> Map.put(acc, key, list)
        _failed, acc -> acc
      end)

    known = Media.held_provider_ids("movie").tmdb

    case results[:radarr] do
      nil ->
        {:error, "radarr discover feed unreachable"}

      movies ->
        available =
          Enum.reject(movies, fn movie ->
            # "announced"/"inCinemas" titles aren't grabbable yet —
            # only "released" (digital/physical out) makes the shelves.
            movie["status"] != "released" or
              movie["isExisting"] == true or movie["isExcluded"] == true or
              MapSet.member?(known, movie["tmdbId"])
          end)

        base = %{
          new_releases: shelf(available, &recent_release?/1, sort: &release_date/1),
          recommended: shelf(available, & &1["isRecommendation"])
        }

        # Trakt's "released" is the theatrical date, so cinema-only
        # titles pass its filter; Radarr's feed knows true grabbability.
        not_grabbable =
          MapSet.new(for movie <- movies, movie["status"] != "released", do: movie["tmdbId"])

        shelves =
          if trakt do
            Map.merge(base, %{
              trending: trakt_movie_shelf(results[:trakt_trending] || [], known, not_grabbable),
              watched: trakt_movie_shelf(results[:trakt_watched] || [], known, not_grabbable)
            })
          else
            Map.merge(base, %{
              trending: shelf(available, & &1["isTrending"]),
              popular: shelf(available, & &1["isPopular"])
            })
          end

        {:ok, shelves}
    end
  end

  defp trakt_movie_shelf(movies, known, not_grabbable) do
    today = Date.utc_today()

    movies
    |> Enum.reject(fn movie ->
      ids = movie["ids"] || %{}

      is_nil(ids["tmdb"]) or MapSet.member?(known, ids["tmdb"]) or
        MapSet.member?(not_grabbable, ids["tmdb"]) or
        trakt_unreleased?(movie, today)
    end)
    |> Enum.take(@shelf_size)
    |> Enum.map(&trakt_candidate(&1, "movie"))
  end

  defp trakt_unreleased?(movie, today) do
    case movie["released"] do
      nil ->
        true

      iso ->
        case Date.from_iso8601(iso) do
          {:ok, date} -> Date.after?(date, today)
          _error -> true
        end
    end
  end

  defp shelf(movies, filter, opts \\ []) do
    movies
    |> Enum.filter(filter)
    |> then(fn list ->
      case opts[:sort] do
        nil -> list
        sorter -> Enum.sort_by(list, sorter, {:desc, Date})
      end
    end)
    |> Enum.take(@shelf_size)
    |> Enum.map(&(&1 |> to_candidate("movie", "radarr-discover") |> Map.put(:match, nil)))
  end

  defp trakt_tv_shelves(connection) do
    held = Media.held_provider_ids("series")
    known_tvdb = held.tvdb
    known_tmdb = held.tmdb

    shelves =
      [:trending, :watched, :popular]
      |> Task.async_stream(
        fn shelf -> {shelf, ArrClient.fetch_trakt_tv(connection, shelf)} end,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {shelf, {:ok, shows}}}, acc ->
          Map.put(acc, shelf, trakt_shelf(shows, known_tvdb, known_tmdb))

        _failed, acc ->
          acc
      end)

    if shelves == %{}, do: {:error, "trakt unreachable"}, else: {:ok, shelves}
  end

  defp trakt_shelf(shows, known_tvdb, known_tmdb) do
    shows
    |> Enum.reject(fn show ->
      ids = show["ids"] || %{}

      (is_nil(ids["tvdb"]) and is_nil(ids["tmdb"])) or
        MapSet.member?(known_tvdb, ids["tvdb"]) or
        MapSet.member?(known_tmdb, ids["tmdb"])
    end)
    |> Enum.take(@shelf_size)
    |> Enum.map(&trakt_candidate(&1, "series"))
  end

  defp trakt_candidate(item, kind) do
    ids = item["ids"] || %{}

    %{
      kind: kind,
      title: item["title"],
      year: item["year"],
      tmdb_id: ids["tmdb"],
      tvdb_id: ids["tvdb"],
      overview: item["overview"],
      genres: item["genres"] || [],
      poster_url: trakt_poster(item),
      rt: nil,
      in_arr: false,
      sources: ["trakt"],
      match: nil,
      lookup: nil
    }
  end

  # Trakt image paths arrive scheme-less ("walter.trakt.tv/...").
  defp trakt_poster(show) do
    case get_in(show, ["images", "poster"]) do
      [path | _rest] when is_binary(path) ->
        if String.starts_with?(path, "http"), do: path, else: "https://" <> path

      _none ->
        nil
    end
  end

  defp tmdb_tv_shelves(connection) do
    known = Media.held_provider_ids("series").tmdb

    shelves =
      [:airing, :trending, :popular]
      |> Task.async_stream(
        fn shelf -> {shelf, ArrClient.fetch_tmdb_tv(connection, shelf)} end,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {shelf, {:ok, results}}}, acc -> Map.put(acc, shelf, tv_shelf(results, known))
        _failed, acc -> acc
      end)

    if shelves == %{}, do: {:error, "tmdb unreachable"}, else: {:ok, shelves}
  end

  defp tv_shelf(results, known) do
    today = Date.utc_today()

    results
    |> Enum.reject(fn show ->
      MapSet.member?(known, show["id"]) or is_nil(show["poster_path"]) or
        future_air_date?(show["first_air_date"], today)
    end)
    |> Enum.take(@shelf_size)
    |> Enum.map(&tv_candidate/1)
  end

  defp future_air_date?(nil, _today), do: true

  defp future_air_date?(iso, today) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Date.after?(date, today)
      _error -> true
    end
  end

  defp tv_candidate(show) do
    %{
      kind: "series",
      title: show["name"],
      year: air_year(show["first_air_date"]),
      tmdb_id: show["id"],
      tvdb_id: nil,
      overview: show["overview"],
      genres: [],
      poster_url: show["poster_path"] && "https://image.tmdb.org/t/p/w500" <> show["poster_path"],
      rt: nil,
      in_arr: false,
      sources: ["tmdb"],
      match: nil,
      lookup: nil
    }
  end

  defp air_year(nil), do: nil

  defp air_year(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date.year
      _error -> nil
    end
  end

  @doc """
  Fills in a TV candidate's tvdb id through Sonarr lookup — matched by
  tmdb id first, air year as fallback. Called at request time; TMDB
  shelf candidates don't carry tvdb ids.
  """
  def resolve_tvdb(%{tvdb_id: tvdb_id}) when is_integer(tvdb_id), do: {:ok, tvdb_id}

  def resolve_tvdb(%{kind: "series"} = candidate) do
    with %{} = connection <- connection_for("series"),
         {:ok, results} <- ArrClient.lookup(connection, candidate.title) do
      match =
        Enum.find(results, &(&1["tmdbId"] == candidate.tmdb_id)) ||
          Enum.find(results, &(abs((&1["year"] || 0) - (candidate.year || 0)) <= 1))

      case match && match["tvdbId"] do
        nil -> :error
        tvdb_id -> {:ok, tvdb_id}
      end
    else
      _unavailable -> :error
    end
  end

  def resolve_tvdb(_candidate), do: :error

  defp recent_release?(movie) do
    case release_date(movie) do
      nil -> false
      date -> Date.diff(Date.utc_today(), date) <= @new_release_window_days
    end
  end

  defp release_date(movie) do
    [movie["digitalRelease"], movie["physicalRelease"], movie["inCinemas"]]
    |> Enum.find_value(fn
      nil ->
        nil

      iso ->
        case DateTime.from_iso8601(iso) do
          {:ok, datetime, _offset} -> DateTime.to_date(datetime)
          _error -> nil
        end
    end)
  end

  @doc """
  Discovers candidates for a library seed item or a free-text query.
  Returns `{:ok, %{candidates: [...], comment: text}}` — candidates are
  maps with title/year/kind/ids/overview/poster_url/genres/rt/match/
  sources. `{:error, reason}` only when nothing can be generated at all.

  Options: `:kind` ("movie" | "series", default "movie").
  """
  def discover(seed_or_query, opts \\ [])

  def discover(%Item{} = seed, opts) do
    kind = Keyword.get(opts, :kind, seed.kind)
    query = "titles like \"#{seed.title}\" (#{seed.year})"
    run(query, seed_vector(seed), seed, kind)
  end

  def discover(query, opts) when is_binary(query) do
    kind = Keyword.get(opts, :kind, "movie")
    run(query, embed_query(query), nil, kind)
  end

  defp run(query, reference_vector, seed, kind) do
    case connection_for(kind) do
      nil ->
        {:error, "no #{arr_for(kind)} connection configured"}

      connection ->
        candidates =
          [
            fn -> llm_candidates(query, seed, kind, connection) end,
            fn -> lookup_candidates(query, seed, kind, connection) end
          ]
          |> Task.async_stream(& &1.(), timeout: 60_000, on_timeout: :kill_task)
          |> Enum.flat_map(fn
            {:ok, list} when is_list(list) -> list
            _failed -> []
          end)
          |> merge_by_provider_id()
          |> reject_in_library(kind)
          |> score(reference_vector)
          |> Enum.take(@max_results)

        {:ok, %{candidates: candidates}}
    end
  end

  ## Sources

  defp llm_candidates(query, seed, kind, connection) do
    with {:ok, titles} <- suggest_titles(query, seed, kind) do
      titles
      |> Task.async_stream(&resolve_title(connection, &1, kind, "llm"),
        max_concurrency: 6,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, candidate}} -> [candidate]
        _unresolved -> []
      end)
    else
      error ->
        Logger.info("discovery: llm source unavailable: #{inspect(error)}")
        []
    end
  end

  defp suggest_titles(query, seed, kind) do
    noun = if kind == "movie", do: "movies", else: "TV series"

    seed_context =
      case seed do
        %Item{} = item ->
          "The reference title: #{item.title} (#{item.year}) — genres " <>
            "#{Enum.join(item.genres, ", ")}. #{String.slice(item.overview || "", 0, 300)}"

        nil ->
          ""
      end

    prompt = """
    Suggest #{@llm_suggestions} #{noun} matching this request: #{query}
    #{seed_context}
    Go beyond the obvious picks; include some deeper cuts.
    Reply with ONLY one title per line in exactly this format, no numbering, no commentary:
    Title (Year)
    """

    # Thinking mode costs ~20s of reasoning tokens for a 15-line answer
    # and degrades it (looping titles) — this call wants extraction speed.
    case Gateway.chat([%{"role" => "user", "content" => prompt}], thinking: false) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        {:ok, parse_titles(content)}

      other ->
        other
    end
  end

  @doc false
  def parse_titles(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Regex.run(~r/^\s*(?:[-*•]+|\d+[.)])?\s*(.+?)\s*\((\d{4})\)/, String.trim(line)) do
        [_all, title, year] -> {String.trim(title), String.to_integer(year)}
        nil -> nil
      end
    end)
    |> Enum.filter(& &1)
    |> Enum.uniq_by(fn {title, _year} -> String.downcase(title) end)
  end

  defp resolve_title(connection, {title, year}, kind, source) do
    with {:ok, results} <- ArrClient.lookup(connection, title) do
      results
      |> Enum.find(fn result -> abs((result["year"] || 0) - year) <= 1 end)
      |> case do
        nil -> {:unresolved, title}
        result -> {:ok, to_candidate(result, kind, source)}
      end
    end
  end

  defp lookup_candidates(query, _seed, kind, connection) do
    case ArrClient.lookup(connection, query) do
      {:ok, results} ->
        results |> Enum.take(@lookup_take) |> Enum.map(&to_candidate(&1, kind, "lookup"))

      {:error, reason} ->
        Logger.info("discovery: lookup source failed: #{inspect(reason)}")
        []
    end
  end

  ## Shaping

  defp to_candidate(result, kind, source) do
    %{
      kind: kind,
      title: result["title"],
      year: result["year"],
      tmdb_id: result["tmdbId"],
      tvdb_id: result["tvdbId"],
      overview: result["overview"],
      genres: result["genres"] || [],
      poster_url: remote_poster(result),
      rt: get_in(result, ["ratings", "rottenTomatoes", "value"]),
      in_arr: is_integer(result["id"]) and result["id"] > 0,
      sources: [source],
      lookup: result
    }
  end

  defp remote_poster(result) do
    result
    |> Map.get("images", [])
    |> Enum.find_value(fn
      %{"coverType" => "poster"} = image -> image["remoteUrl"] || image["url"]
      _other -> nil
    end)
    |> case do
      nil -> result["remotePoster"]
      url -> url
    end
    |> card_size()
  end

  # TMDB's `original` posters are multi-MB; cards only need w500.
  defp card_size(nil), do: nil

  defp card_size(url) do
    if String.contains?(url, "image.tmdb.org"),
      do: String.replace(url, "/original/", "/w500/"),
      else: url
  end

  defp merge_by_provider_id(candidates) do
    candidates
    |> Enum.group_by(&{&1.kind, provider_id(&1)})
    |> Enum.map(fn {_key, [first | rest]} ->
      %{first | sources: Enum.uniq(first.sources ++ Enum.flat_map(rest, & &1.sources))}
    end)
  end

  defp provider_id(%{kind: "movie"} = candidate), do: candidate.tmdb_id
  defp provider_id(%{kind: "series"} = candidate), do: candidate.tvdb_id

  defp reject_in_library(candidates, kind) do
    held = Media.held_provider_ids(kind)

    known =
      case kind do
        "movie" -> held.tmdb
        "series" -> held.tvdb
      end

    Enum.reject(candidates, fn candidate ->
      candidate.in_arr or is_nil(provider_id(candidate)) or
        MapSet.member?(known, provider_id(candidate))
    end)
  end

  ## Scoring

  defp score(candidates, nil), do: candidates |> Enum.map(&Map.put(&1, :match, nil))

  defp score(candidates, reference_vector) do
    texts =
      Enum.map(candidates, fn candidate ->
        "#{candidate.title} (#{candidate.year}) — #{candidate.kind}\n" <>
          "genres: #{Enum.join(candidate.genres, ", ")}\n#{candidate.overview || ""}"
      end)

    case texts != [] && Gateway.embed(texts) do
      {:ok, %{"data" => data}} when length(data) == length(candidates) ->
        vectors = data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])

        candidates
        |> Enum.zip(vectors)
        |> Enum.map(fn {candidate, vector} ->
          Map.put(candidate, :match, round(cosine(reference_vector, vector) * 100))
        end)
        |> Enum.sort_by(& &1.match, :desc)

      _unavailable ->
        Enum.map(candidates, &Map.put(&1, :match, nil))
    end
  end

  @doc false
  def cosine(a, b) do
    {dot, norm_a, norm_b} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, na, nb} ->
        {dot + x * y, na + x * x, nb + y * y}
      end)

    if norm_a == 0.0 or norm_b == 0.0,
      do: 0.0,
      else: dot / (:math.sqrt(norm_a) * :math.sqrt(norm_b))
  end

  defp seed_vector(%Item{embedding: nil}), do: nil
  defp seed_vector(%Item{embedding: embedding}), do: Pgvector.to_list(embedding)

  defp embed_query(query) do
    case Gateway.embed(query) do
      {:ok, %{"data" => [%{"embedding" => vector} | _rest]}} -> vector
      _unavailable -> nil
    end
  end

  defp arr_for("movie"), do: "radarr"
  defp arr_for("series"), do: "sonarr"

  defp connection_for(kind) do
    kind |> arr_for() |> Integrations.list_connections() |> List.first()
  end
end
