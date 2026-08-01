defmodule MediaAssist.Media.SyncWorker do
  @moduledoc """
  Caches the arrstack libraries into the media index. Walks every
  enabled Radarr/Sonarr connection (respecting the index settings) and
  upserts each returned title via `Media.upsert_item/1`.

  When `embed_on_sync` is set, a `Media.EmbedWorker` is enqueued
  afterward to vectorize whatever the sync brought in. Edge-building
  from watch history is the next layer.
  """

  use Oban.Worker,
    queue: :indexer,
    max_attempts: 3,
    unique: [period: :infinity, states: Oban.Job.states() -- [:completed, :discarded, :cancelled]]

  require Logger

  alias MediaAssist.Integrations
  alias MediaAssist.Integrations.ArrClient
  alias MediaAssist.Media

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    settings = Integrations.get_index_settings()

    results =
      sync_service(settings.sync_movies, "radarr", "movie") ++
        sync_service(settings.sync_series, "sonarr", "series")

    Integrations.mark_synced()

    if settings.embed_on_sync do
      Oban.insert(MediaAssist.Media.EmbedWorker.new(%{}))
    end

    Oban.insert(MediaAssist.Media.WatchSyncWorker.new(%{}))

    for user <- MediaAssist.Accounts.list_users(), user.trakt_username do
      Oban.insert(MediaAssist.Media.TraktImportWorker.new(%{"user_id" => user.id}))
    end

    Logger.info("media sync: #{inspect(results)}")
    :ok
  end

  defp sync_service(false, _service, _kind), do: []

  defp sync_service(true, service, kind) do
    connections = Integrations.list_connections(service)

    {results, seen_ids, all_ok} =
      Enum.reduce(connections, {[], MapSet.new(), connections != []}, fn connection,
                                                                         {results, seen, ok} ->
        case ArrClient.fetch_library(connection) do
          {:ok, rows} when is_list(rows) ->
            count =
              rows
              |> Enum.map(&upsert_row(&1, service, kind))
              |> Enum.count(&match?({:ok, _}, &1))

            {[{connection.name, {:synced, count}} | results], Enum.into(rows, seen, & &1["id"]),
             ok}

          {:error, reason} ->
            Logger.warning("media sync: #{connection.name} failed: #{inspect(reason)}")
            {[{connection.name, {:error, reason}} | results], seen, false}
        end
      end)

    # Departure detection only on a complete picture: every connection
    # for this service answered — a fetch failure must never mass-depart.
    if all_ok do
      {departed, _} = Media.mark_departed(service, MapSet.to_list(seen_ids))
      if departed > 0, do: Logger.info("media sync: #{departed} #{service} items departed")
    end

    Enum.reverse(results)
  end

  defp upsert_row(row, service, kind) do
    Media.upsert_item(%{
      kind: kind,
      title: row["title"],
      year: row["year"],
      overview: row["overview"],
      genres: row["genres"] || [],
      tmdb_id: row["tmdbId"],
      tvdb_id: row["tvdbId"],
      imdb_id: row["imdbId"],
      service: service,
      service_item_id: row["id"],
      poster_url: poster_url(row),
      status: status(row, kind),
      ratings: Media.normalize_ratings(row["ratings"]),
      # Present in the arr again — a stale departure timestamp would lie.
      departed_at: nil,
      added_at: parse_added(row["added"]),
      synced_at: DateTime.utc_now(:second)
    })
  end

  defp parse_added(nil), do: nil

  defp parse_added(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _error -> nil
    end
  end

  defp poster_url(row) do
    row
    |> Map.get("images", [])
    |> Enum.find_value(fn
      %{"coverType" => "poster"} = image -> image["remoteUrl"] || image["url"]
      _other -> nil
    end)
  end

  defp status(%{"hasFile" => true}, "movie"), do: "in_library"
  defp status(%{"hasFile" => false}, "movie"), do: "missing"

  defp status(%{"statistics" => %{"episodeFileCount" => n}}, "series") when n > 0,
    do: "in_library"

  defp status(_row, _kind), do: "missing"
end
