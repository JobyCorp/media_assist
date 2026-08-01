defmodule MediaAssist.Integrations.ArrClient do
  @moduledoc """
  Thin HTTP client for the backend media services. Radarr and Sonarr
  speak the same v3 API shape (`X-Api-Key` header); SABnzbd
  authenticates via the `apikey` query param; Emby uses the
  `X-Emby-Token` header.

  Only what the scaffold needs so far: `ping/1` for connectivity checks
  and `fetch_library/1` for the media index sync. Emby watch-history
  collection builds on this next.
  """

  alias MediaAssist.Integrations.Connection

  @receive_timeout 10_000

  @doc "Connectivity check. Returns `:ok` or `{:error, reason}`."
  def ping(%Connection{service: service} = conn) when service in ["radarr", "sonarr"] do
    case get(conn, "/api/v3/system/status") do
      {:ok, %{"version" => _}} -> :ok
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Trakt public lists need a valid client id in the headers.
  def ping(%Connection{service: "trakt"} = conn) do
    case get(conn, "/shows/trending", limit: 1) do
      {:ok, list} when is_list(list) -> :ok
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # /3/configuration requires valid auth, so the check proves the key.
  def ping(%Connection{service: "tmdb"} = conn) do
    case get(conn, "/3/configuration") do
      {:ok, %{"images" => _images}} -> :ok
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # /System/Info requires a valid token (unlike /System/Info/Public),
  # so the check proves auth, not just reachability.
  def ping(%Connection{service: "emby"} = conn) do
    case get(conn, "/System/Info") do
      {:ok, %{"Version" => _}} -> :ok
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # mode=queue (unlike mode=version) requires a valid API key, so the
  # check proves auth, not just reachability.
  def ping(%Connection{service: "sabnzbd"} = conn) do
    case get(conn, "/api", mode: "queue") do
      {:ok, %{"queue" => _}} -> :ok
      {:ok, %{"error" => error}} -> {:error, {:auth, error}}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches the full library from a Radarr (movies) or Sonarr (series)
  connection as a list of raw API maps.
  """
  def fetch_library(%Connection{service: "radarr"} = conn), do: get(conn, "/api/v3/movie")
  def fetch_library(%Connection{service: "sonarr"} = conn), do: get(conn, "/api/v3/series")

  def fetch_library(%Connection{service: service}),
    do: {:error, {:no_library, service}}

  @doc """
  An Emby user's played items of one kind ("movie" | "series"), with
  provider ids and per-user play data. Movies use Emby's `IsPlayed`
  filter; series come back unfiltered (Emby only marks a series Played
  when fully watched) and get filtered on play data by the caller.
  """
  def fetch_emby_played(%Connection{service: "emby"} = conn, emby_user_id, kind) do
    params =
      case kind do
        "movie" ->
          [IncludeItemTypes: "Movie", Recursive: true, Filters: "IsPlayed", Fields: "ProviderIds"]

        "series" ->
          [IncludeItemTypes: "Series", Recursive: true, Fields: "ProviderIds"]
      end

    case get(conn, "/Users/#{emby_user_id}/Items", params) do
      {:ok, %{"Items" => items}} -> {:ok, items}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Term search against Radarr/Sonarr's metadata service. Returns
  candidates beyond the library — in-library results carry a positive
  `"id"`. The discovery pipeline's resolution step.
  """
  def lookup(%Connection{service: "radarr"} = conn, term),
    do: get(conn, "/api/v3/movie/lookup", term: term)

  def lookup(%Connection{service: "sonarr"} = conn, term),
    do: get(conn, "/api/v3/series/lookup", term: term)

  @trakt_tv_paths %{
    trending: "/shows/trending",
    watched: "/shows/watched/weekly",
    popular: "/shows/popular"
  }

  @doc """
  A Trakt TV list (`:trending` — being watched right now, `:watched` —
  most watched this week, `:popular`) as flat show maps. Trakt wraps
  trending/watched entries in stats objects; this unwraps them. Shows
  carry `ids.tvdb` / `ids.tmdb` directly.
  """
  def fetch_trakt_tv(%Connection{service: "trakt"} = conn, shelf)
      when is_map_key(@trakt_tv_paths, shelf) do
    case get(conn, @trakt_tv_paths[shelf], limit: 24, extended: "full,images") do
      {:ok, items} when is_list(items) ->
        {:ok, Enum.map(items, fn item -> item["show"] || item end)}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @trakt_movie_paths %{
    trending: "/movies/trending",
    watched: "/movies/watched/weekly"
  }

  @doc """
  A Trakt movie list (`:trending` — being watched right now, `:watched`
  — most watched this week) as flat movie maps, stats wrappers unwrapped.
  """
  def fetch_trakt_movies(%Connection{service: "trakt"} = conn, shelf)
      when is_map_key(@trakt_movie_paths, shelf) do
    case get(conn, @trakt_movie_paths[shelf], limit: 24, extended: "full,images") do
      {:ok, items} when is_list(items) ->
        {:ok, Enum.map(items, fn item -> item["movie"] || item end)}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  A Trakt user's complete watched aggregate for one kind: entries of
  `%{"plays", "last_watched_at", "movie"|"show" => metadata}` with full
  metadata and images. One call covers the whole history. Requires a
  public profile (private → http 401/403).
  """
  def fetch_trakt_user_watched(%Connection{service: "trakt"} = conn, username, kind) do
    noun = if kind == "movie", do: "movies", else: "shows"

    # Requesting images turns pagination on (default 100/page) — walk
    # every page so long histories import completely.
    fetch_trakt_pages(
      conn,
      "/users/#{username}/watched/#{noun}",
      [extended: "full,images"],
      1,
      []
    )
  end

  @trakt_page_size 200
  @trakt_max_pages 100

  defp fetch_trakt_pages(conn, path, params, page, acc) when page <= @trakt_max_pages do
    case get(conn, path, params ++ [limit: @trakt_page_size, page: page]) do
      {:ok, items} when is_list(items) ->
        acc = acc ++ items

        if length(items) < @trakt_page_size,
          do: {:ok, acc},
          else: fetch_trakt_pages(conn, path, params, page + 1, acc)

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_trakt_pages(_conn, _path, _params, _page, acc), do: {:ok, acc}

  @doc """
  A Trakt user's explicit ratings for one kind: entries of
  `%{"rating" => 1..10, "rated_at", "movie"|"show" => %{"ids" => ...}}`.
  """
  def fetch_trakt_user_ratings(%Connection{service: "trakt"} = conn, username, kind) do
    noun = if kind == "movie", do: "movies", else: "shows"
    fetch_trakt_pages(conn, "/users/#{username}/ratings/#{noun}", [], 1, [])
  end

  @tmdb_tv_paths %{
    trending: "/3/trending/tv/week",
    popular: "/3/tv/popular",
    airing: "/3/tv/on_the_air"
  }

  @doc """
  A TMDB TV list (`:trending` | `:popular` | `:airing`) as raw TMDB
  result maps (`"id"` is the tmdb id; no tvdb id — resolve via Sonarr
  lookup when needed).
  """
  def fetch_tmdb_tv(%Connection{service: "tmdb"} = conn, shelf)
      when is_map_key(@tmdb_tv_paths, shelf) do
    case get(conn, @tmdb_tv_paths[shelf]) do
      {:ok, %{"results" => results}} -> {:ok, results}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  SABnzbd's active download queue as a list of
  `%{name, percentage, timeleft, size_mb, status}` maps.
  """
  def fetch_sab_queue(%Connection{service: "sabnzbd"} = conn) do
    case get(conn, "/api", mode: "queue") do
      {:ok, %{"queue" => %{"slots" => slots}}} ->
        {:ok,
         Enum.map(slots, fn slot ->
           %{
             name: slot["filename"],
             percentage: parse_number(slot["percentage"]),
             timeleft: slot["timeleft"],
             size_mb: parse_number(slot["mb"]),
             status: slot["status"]
           }
         end)}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_number(value) when is_number(value), do: value

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp parse_number(_other), do: 0

  @doc """
  Radarr's Discover feed: TMDB trending/popular plus recommendations
  derived from the library, one call, no TMDB key needed. Rows carry
  `isTrending` / `isPopular` / `isRecommendation` / `isExisting` flags.
  """
  def discover_movies(%Connection{service: "radarr"} = conn) do
    get(conn, "/api/v3/importlist/movie",
      includeRecommendations: true,
      includeTrending: true,
      includePopular: true
    )
  end

  @doc "Radarr/Sonarr quality profiles, for add defaults."
  def quality_profiles(%Connection{} = conn), do: get(conn, "/api/v3/qualityprofile")

  @doc "Radarr/Sonarr root folders, for add defaults."
  def root_folders(%Connection{} = conn), do: get(conn, "/api/v3/rootfolder")

  @doc """
  Adds a movie (Radarr) or series (Sonarr) and triggers a search for it.
  `lookup_result` is a raw map from `lookup/2` — the arr wants its own
  lookup shape back, plus profile/folder/monitoring fields.
  """
  def add(%Connection{service: "radarr"} = conn, lookup_result, profile_id, root_folder) do
    payload =
      Map.merge(lookup_result, %{
        "qualityProfileId" => profile_id,
        "rootFolderPath" => root_folder,
        "monitored" => true,
        "addOptions" => %{"searchForMovie" => true}
      })

    post(conn, "/api/v3/movie", payload)
  end

  def add(%Connection{service: "sonarr"} = conn, lookup_result, profile_id, root_folder) do
    payload =
      Map.merge(lookup_result, %{
        "qualityProfileId" => profile_id,
        "rootFolderPath" => root_folder,
        "monitored" => true,
        "addOptions" => %{"searchForMissingEpisodes" => true}
      })

    post(conn, "/api/v3/series", payload)
  end

  @doc """
  One Emby item with full per-user data. Emby trims `UserData` (no
  `LastPlayedDate`, zeroed `PlayCount`) in list responses; the detail
  endpoint carries the real values.
  """
  def fetch_emby_item(%Connection{service: "emby"} = conn, emby_user_id, emby_item_id) do
    get(conn, "/Users/#{emby_user_id}/Items/#{emby_item_id}")
  end

  @doc """
  Lists the Emby server's users as `%{id, name}` maps, for mapping app
  accounts to Emby profiles.
  """
  def fetch_emby_users(%Connection{service: "emby"} = conn) do
    case get(conn, "/Users") do
      {:ok, users} when is_list(users) ->
        {:ok, for(%{"Id" => id, "Name" => name} <- users, do: %{id: id, name: name})}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get(%Connection{} = conn, path, params \\ []) do
    url = String.trim_trailing(conn.base_url, "/") <> path

    request =
      case conn.service do
        "sabnzbd" ->
          [url: url, params: Keyword.merge(params, apikey: conn.api_key, output: "json")]

        "emby" ->
          [url: url, params: params, headers: [{"x-emby-token", conn.api_key}]]

        # Trakt public lists: client id + API version in headers.
        "trakt" ->
          [
            url: url,
            params: params,
            headers: [{"trakt-api-key", conn.api_key}, {"trakt-api-version", "2"}]
          ]

        # TMDB v4 read tokens are JWTs (Bearer); v3 keys go in the query.
        "tmdb" ->
          if String.starts_with?(conn.api_key, "eyJ") do
            [url: url, params: params, headers: [{"authorization", "Bearer " <> conn.api_key}]]
          else
            [url: url, params: Keyword.put(params, :api_key, conn.api_key)]
          end

        _arr ->
          [url: url, params: params, headers: [{"x-api-key", conn.api_key}]]
      end

    case Req.get(Keyword.merge(request, receive_timeout: @receive_timeout, retry: false)) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp post(%Connection{} = conn, path, payload) do
    url = String.trim_trailing(conn.base_url, "/") <> path

    request = [
      url: url,
      json: payload,
      headers: [{"x-api-key", conn.api_key}],
      receive_timeout: @receive_timeout,
      retry: false
    ]

    case Req.post(request) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, summarize(body)}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  end

  # Arr validation errors arrive as a list of maps; keep the messages.
  defp summarize(body) when is_list(body),
    do: Enum.map_join(body, "; ", &(&1["errorMessage"] || inspect(&1)))

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(body), do: inspect(body) |> String.slice(0, 200)
end
