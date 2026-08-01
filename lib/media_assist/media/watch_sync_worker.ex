defmodule MediaAssist.Media.WatchSyncWorker do
  @moduledoc """
  Pulls watch history from Emby for every app user mapped to an Emby
  profile: played movies and series, matched to index items by provider
  ids (tmdb/tvdb/imdb), upserted as `Media.Watch` rows.

  No-ops cleanly when there's no Emby connection or no mapped users, so
  it can sit in the standard sync chain. Unmatched Emby items (not in
  the arrstack index) are counted and logged, not treated as errors.
  """

  use Oban.Worker,
    queue: :indexer,
    max_attempts: 3,
    unique: [period: 60, states: Oban.Job.states() -- [:completed, :discarded, :cancelled]]

  require Logger

  alias MediaAssist.Accounts
  alias MediaAssist.Integrations
  alias MediaAssist.Integrations.ArrClient
  alias MediaAssist.Media

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Integrations.list_connections("emby") do
      [] ->
        Logger.info("watch sync: no emby connection — skipping")
        :ok

      [connection | _rest] ->
        mapped_users = Enum.filter(Accounts.list_users(), & &1.emby_user_id)

        results =
          for user <- mapped_users, kind <- ["movie", "series"] do
            {handle(user), kind, sync_user_kind(connection, user, kind)}
          end

        Logger.info("watch sync: #{inspect(results)}")

        if Enum.any?(results, &match?({_user, _kind, {:error, _}}, &1)),
          do: {:error, :partial_failure},
          else: :ok
    end
  end

  defp sync_user_kind(connection, user, kind) do
    case ArrClient.fetch_emby_played(connection, user.emby_user_id, kind) do
      {:ok, emby_items} ->
        played = Enum.filter(emby_items, &played?(&1, kind))

        {matched, unmatched} =
          Enum.split_with(
            Enum.map(played, &{&1, match_item(&1, kind)}),
            fn {_emby_item, item} -> item end
          )

        matched
        |> Task.async_stream(
          fn {emby_item, item} -> record_watch(connection, user, emby_item, item) end,
          max_concurrency: 8,
          timeout: 30_000
        )
        |> Stream.run()

        if unmatched != [] do
          Logger.info(
            "watch sync: #{handle(user)}/#{kind} — #{length(unmatched)} emby titles not in index"
          )
        end

        {:ok, matched: length(matched), unmatched: length(unmatched)}

      {:error, reason} ->
        Logger.warning("watch sync: #{handle(user)}/#{kind} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Movies arrive pre-filtered by IsPlayed; series count as watched with
  # any play progress.
  defp played?(_emby_item, "movie"), do: true

  defp played?(%{"UserData" => user_data}, "series") do
    user_data["Played"] == true or (user_data["PlayCount"] || 0) > 0 or
      (user_data["PlayedPercentage"] || 0) > 0
  end

  defp played?(_emby_item, "series"), do: false

  defp match_item(emby_item, kind) do
    provider_ids = emby_item["ProviderIds"] || %{}

    Media.find_item_by_provider_ids(kind, %{
      tmdb: provider_value(provider_ids, "tmdb"),
      tvdb: provider_value(provider_ids, "tvdb"),
      imdb: provider_value(provider_ids, "imdb")
    })
  end

  # The list response's UserData is trimmed (no LastPlayedDate, zeroed
  # PlayCount), so each matched item is enriched from the detail
  # endpoint; on failure the trimmed data is still recorded.
  defp record_watch(connection, user, emby_item, item) do
    user_data =
      case ArrClient.fetch_emby_item(connection, user.emby_user_id, emby_item["Id"]) do
        {:ok, %{"UserData" => detail_user_data}} -> detail_user_data
        _error -> emby_item["UserData"] || %{}
      end

    Media.upsert_watch(user, item,
      play_count: max(user_data["PlayCount"] || 1, 1),
      last_played_at: parse_played_at(user_data["LastPlayedDate"]),
      favorite: user_data["IsFavorite"] == true,
      # Emby omits Likes entirely until the user thumbs; nil = unset.
      liked: user_data["Likes"]
    )
  end

  # Emby capitalizes provider keys inconsistently ("Tmdb", "tmdb", "TMDB").
  defp provider_value(provider_ids, key) do
    Enum.find_value(provider_ids, fn {k, value} ->
      String.downcase(k) == key && value
    end)
  end

  defp parse_played_at(nil), do: nil

  defp parse_played_at(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _error -> nil
    end
  end

  defp handle(user), do: user.email |> String.split("@") |> hd()
end
