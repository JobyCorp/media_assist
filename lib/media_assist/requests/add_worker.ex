defmodule MediaAssist.Requests.AddWorker do
  @moduledoc """
  Pushes a pending request into Radarr (movies) or Sonarr (series):
  re-resolves the title through the arr's lookup (the add endpoint wants
  its own lookup shape back), applies the first quality profile and root
  folder as defaults, and triggers a search. Marks the request
  `added`/`failed`; a follow-up library sync picks up the new item.
  """

  use Oban.Worker, queue: :indexer, max_attempts: 2

  require Logger

  alias MediaAssist.Integrations
  alias MediaAssist.Integrations.ArrClient
  alias MediaAssist.Requests

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"request_id" => request_id}}) do
    request = Requests.get_request!(request_id)
    service = if request.kind == "movie", do: "radarr", else: "sonarr"

    result =
      with {:connection, [connection | _rest]} <-
             {:connection, Integrations.list_connections(service)},
           {:ok, lookup_result} <- find_lookup_match(connection, request),
           {:ok, profile_id} <- default_profile(connection),
           {:ok, root_folder} <- default_root_folder(connection),
           {:ok, _added} <- ArrClient.add(connection, lookup_result, profile_id, root_folder) do
        :ok
      else
        {:connection, []} -> {:error, "no #{service} connection configured"}
        {:error, reason} -> {:error, inspect(reason)}
      end

    case result do
      :ok ->
        Requests.mark_added(request)
        Oban.insert(MediaAssist.Media.SyncWorker.new(%{}))
        :ok

      {:error, message} ->
        Logger.warning("request add failed: #{request.title} — #{message}")
        Requests.mark_failed(request, message)
        {:error, message}
    end
  end

  defp find_lookup_match(connection, request) do
    with {:ok, results} <- ArrClient.lookup(connection, request.title) do
      match =
        Enum.find(results, fn result ->
          case request.kind do
            "movie" -> result["tmdbId"] == request.tmdb_id
            "series" -> result["tvdbId"] == request.tvdb_id
          end
        end)

      if match, do: {:ok, match}, else: {:error, "lookup no longer resolves #{request.title}"}
    end
  end

  defp default_profile(connection) do
    case ArrClient.quality_profiles(connection) do
      {:ok, [profile | _rest]} -> {:ok, profile["id"]}
      {:ok, []} -> {:error, "no quality profiles on #{connection.name}"}
      error -> error
    end
  end

  defp default_root_folder(connection) do
    case ArrClient.root_folders(connection) do
      {:ok, [folder | _rest]} -> {:ok, folder["path"]}
      {:ok, []} -> {:error, "no root folders on #{connection.name}"}
      error -> error
    end
  end
end
