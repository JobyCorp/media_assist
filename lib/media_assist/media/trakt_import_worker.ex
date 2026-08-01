defmodule MediaAssist.Media.TraktImportWorker do
  @moduledoc """
  Imports a user's Trakt watch history into the catalog. Two calls per
  kind (full watched aggregate + ratings); titles already cataloged get
  their watch merged, unknown titles become `known` items built from
  Trakt's own metadata (no arr involvement) — the antidote to
  survivorship bias: seen-and-deleted or never-held media enters the
  taste signal.

  `Media.merge_watch/3` semantics protect Emby-sourced data: play counts
  and recency only ratchet up, hearts/thumbs are untouched. Finishes by
  enqueueing the embed worker so new `known` items join the vector space.
  """

  use Oban.Worker,
    queue: :indexer,
    max_attempts: 2,
    unique: [period: 60, states: Oban.Job.states() -- [:completed, :discarded, :cancelled]]

  require Logger

  alias MediaAssist.Accounts
  alias MediaAssist.Integrations
  alias MediaAssist.Integrations.ArrClient
  alias MediaAssist.Media

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    user = Accounts.get_user!(user_id)

    with {:username, username} when is_binary(username) <- {:username, user.trakt_username},
         {:connection, [connection | _rest]} <- {:connection, Integrations.list_connections("trakt")} do
      results =
        for kind <- ["movie", "series"] do
          {kind, import_kind(connection, user, username, kind)}
        end

      Logger.info("trakt import (#{username}): #{inspect(results)}")
      backfill_posters()
      Oban.insert(MediaAssist.Media.EmbedWorker.new(%{}))

      if Enum.any?(results, &match?({_kind, {:error, _}}, &1)),
        do: {:error, :partial_failure},
        else: :ok
    else
      {:username, _none} ->
        Logger.info("trakt import: user has no trakt username — skipping")
        :ok

      {:connection, []} ->
        Logger.info("trakt import: no trakt connection — skipping")
        :ok
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  # Trakt's watched-shows endpoint omits images (movies carry them), so
  # posterless imports get artwork + external ratings from the arr's
  # metadata lookup, matched by provider id.
  defp backfill_posters do
    for {kind, service} <- [{"movie", "radarr"}, {"series", "sonarr"}],
        connection = Integrations.list_connections(service) |> List.first(),
        connection != nil do
      kind
      |> Media.list_items_missing_posters()
      |> Task.async_stream(&backfill_item(connection, &1),
        max_concurrency: 6,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Stream.run()
    end
  end

  defp backfill_item(connection, item) do
    with {:ok, results} <- ArrClient.lookup(connection, item.title),
         %{} = match <- find_provider_match(results, item) do
      poster =
        match
        |> Map.get("images", [])
        |> Enum.find_value(fn
          %{"coverType" => "poster"} = image -> image["remoteUrl"] || image["url"]
          _other -> nil
        end) || match["remotePoster"]

      ratings = Media.normalize_ratings(match["ratings"])

      item
      |> Ecto.Changeset.change(
        poster_url: poster,
        ratings: Map.merge(ratings, item.ratings)
      )
      |> MediaAssist.Repo.update()
    else
      _unmatched -> :skip
    end
  end

  defp find_provider_match(results, item) do
    Enum.find(results, fn result ->
      (item.tmdb_id && result["tmdbId"] == item.tmdb_id) or
        (item.tvdb_id && result["tvdbId"] == item.tvdb_id)
    end)
  end

  defp import_kind(connection, user, username, kind) do
    with {:ok, watched} <- ArrClient.fetch_trakt_user_watched(connection, username, kind),
         {:ok, ratings} <- ArrClient.fetch_trakt_user_ratings(connection, username, kind) do
      ratings_by_trakt_id =
        Map.new(ratings, fn entry ->
          {get_in(entry, [media_key(kind), "ids", "trakt"]), entry["rating"]}
        end)

      counts =
        watched
        |> Enum.map(&import_entry(user, kind, &1, ratings_by_trakt_id))
        |> Enum.frequencies()

      {:ok, counts}
    else
      {:error, reason} ->
        Logger.warning("trakt import: #{username}/#{kind} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp import_entry(user, kind, entry, ratings_by_trakt_id) do
    media = entry[media_key(kind)] || %{}
    ids = media["ids"] || %{}

    with {:ok, item} <- find_or_create_item(kind, media, ids),
         {:ok, _watch} <-
           Media.merge_watch(user, item,
             play_count: max(entry["plays"] || 1, 1),
             last_played_at: parse_datetime(entry["last_watched_at"]),
             rating: ratings_by_trakt_id[ids["trakt"]]
           ) do
      :imported
    else
      _skipped -> :skipped
    end
  end

  defp find_or_create_item(kind, media, ids) do
    case Media.find_item_by_provider_ids(kind, %{
           tmdb: ids["tmdb"],
           tvdb: ids["tvdb"],
           imdb: ids["imdb"]
         }) do
      nil -> create_known_item(kind, media, ids)
      item -> {:ok, item}
    end
  end

  defp create_known_item(_kind, %{"title" => nil}, _ids), do: :skipped

  defp create_known_item(kind, media, ids) do
    Media.upsert_item(%{
      kind: kind,
      title: media["title"],
      year: media["year"],
      overview: media["overview"],
      genres: media["genres"] || [],
      tmdb_id: ids["tmdb"],
      tvdb_id: ids["tvdb"],
      imdb_id: ids["imdb"],
      service: "trakt",
      service_item_id: nil,
      poster_url: trakt_poster(media),
      status: "known",
      ratings: trakt_community_rating(media)
    })
  end

  defp trakt_poster(media) do
    case get_in(media, ["images", "poster"]) do
      [path | _rest] when is_binary(path) ->
        if String.starts_with?(path, "http"), do: path, else: "https://" <> path

      _none ->
        nil
    end
  end

  defp trakt_community_rating(%{"rating" => rating}) when is_number(rating) and rating > 0,
    do: %{"trakt" => Float.round(rating * 1.0, 2)}

  defp trakt_community_rating(_media), do: %{}

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _error -> nil
    end
  end

  defp media_key("movie"), do: "movie"
  defp media_key("series"), do: "show"
end
