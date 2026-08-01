defmodule MediaAssist.MCP.Tools do
  @moduledoc """
  Tool implementations for the MCP endpoint. Deliberately thin: every
  tool maps onto an existing context function and this module only
  shapes arguments and results. `call/3` returns `{:ok, payload}` with a
  JSON-encodable map, `{:error, message}` for domain failures the
  calling agent should read, or `{:error, :unknown_tool}`.

  `similar_media` is pure pgvector (`Media.similar_items_with_distance`)
  on purpose — `Discovery.discover/2` costs gateway tokens and the MCP
  caller is itself an agent that can iterate on `search_media`.
  """

  alias MediaAssist.Accounts.Scope
  alias MediaAssist.Integrations
  alias MediaAssist.Integrations.ArrClient
  alias MediaAssist.Media
  alias MediaAssist.Media.Item
  alias MediaAssist.Requests

  @statuses ~w(held all in_library missing departed known)
  @max_page_size 100

  def descriptors do
    [
      %{
        name: "list_media",
        description:
          "List catalog items with filters and pagination. `status` \"held\" " <>
            "(default) means the arrs hold or monitor the title; \"all\" includes " <>
            "departed and known-but-never-held titles.",
        inputSchema: %{
          type: "object",
          properties: %{
            kind: %{type: "string", enum: ["movie", "series"]},
            status: %{type: "string", enum: @statuses},
            genre: %{type: "string"},
            limit: %{type: "integer", description: "Page size, max #{@max_page_size}."},
            page: %{type: "integer"}
          }
        }
      },
      %{
        name: "get_media",
        description: "Full detail for one catalog item by id, including who has watched it.",
        inputSchema: %{
          type: "object",
          properties: %{id: %{type: "string", description: "Catalog item UUID."}},
          required: ["id"]
        }
      },
      %{
        name: "search_media",
        description:
          "Search the catalog by title. With `include_new: true` (requires `kind`), " <>
            "also looks up titles not in the catalog via Radarr/Sonarr — those " <>
            "results carry provider ids usable with `request_media`.",
        inputSchema: %{
          type: "object",
          properties: %{
            query: %{type: "string"},
            kind: %{type: "string", enum: ["movie", "series"]},
            include_new: %{type: "boolean", default: false}
          },
          required: ["query"]
        }
      },
      %{
        name: "request_media",
        description:
          "Request a title the library doesn't hold. Submits to Radarr/Sonarr as " <>
            "the API token's user, same flow as the UI. Movies need `tmdb_id`, " <>
            "series need `tvdb_id` (get them from `search_media` with `include_new`).",
        inputSchema: %{
          type: "object",
          properties: %{
            kind: %{type: "string", enum: ["movie", "series"]},
            title: %{type: "string"},
            year: %{type: "integer"},
            tmdb_id: %{type: "integer"},
            tvdb_id: %{type: "integer"},
            poster_url: %{type: "string"}
          },
          required: ["kind", "title"]
        }
      },
      %{
        name: "media_status",
        description:
          "System snapshot: catalog counts, watch totals, recent requests, and " <>
            "the active download queue.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "similar_media",
        description:
          "Titles most similar to a seed item, by embedding distance (lower is " <>
            "closer). Seed by catalog `id` or by `title`.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string"},
            title: %{type: "string"},
            limit: %{type: "integer", default: 10, maximum: 25}
          }
        }
      }
    ]
  end

  def call("list_media", args, _scope) do
    result =
      Media.search_items(
        kind: args["kind"],
        genre: args["genre"],
        presence: args["status"] || "held",
        per_page: args |> int(bounds: {1, @max_page_size}, key: "limit", default: 25),
        page: int(args, key: "page", default: 1, bounds: {1, 1_000_000})
      )

    {:ok,
     %{
       items: Enum.map(result.items, &item_row/1),
       total: result.total,
       page: result.page,
       pages: result.pages
     }}
  end

  def call("get_media", %{"id" => id}, _scope) do
    case Media.fetch_item(id) do
      {:ok, item} -> {:ok, item_detail(item)}
      :error -> {:error, "no catalog item with id #{id}"}
    end
  end

  def call("get_media", _args, _scope), do: {:error, "get_media requires an id"}

  def call("search_media", %{"query" => query} = args, _scope) when is_binary(query) do
    kind = args["kind"]

    library =
      Media.search_items(q: query, kind: kind, presence: "all", per_page: 20)
      |> Map.fetch!(:items)
      |> Enum.map(&item_row/1)

    if args["include_new"] do
      with {:ok, kind} <- require_kind(kind),
           {:ok, candidates} <- lookup_new(kind, query) do
        {:ok, %{library: library, new: candidates}}
      end
    else
      {:ok, %{library: library}}
    end
  end

  def call("search_media", _args, _scope), do: {:error, "search_media requires a query"}

  def call("request_media", args, %Scope{user: user}) do
    attrs = %{
      kind: args["kind"],
      title: args["title"],
      year: args["year"],
      tmdb_id: args["tmdb_id"],
      tvdb_id: args["tvdb_id"],
      poster_url: args["poster_url"]
    }

    case Requests.create_request(user, attrs) do
      {:ok, request} ->
        {:ok,
         %{
           id: request.id,
           title: request.title,
           kind: request.kind,
           status: request.status,
           note: "queued — the add worker submits it to #{arr_for(request.kind)}"
         }}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "request rejected: #{changeset_message(changeset)}"}
    end
  end

  def call("media_status", _args, _scope) do
    requests =
      Requests.list_recent_requests(10)
      |> Enum.map(
        &%{
          title: &1.title,
          kind: &1.kind,
          status: &1.status,
          error: &1.error,
          requested_by: &1.user && handle(&1.user),
          at: &1.inserted_at
        }
      )

    downloads =
      case Integrations.sab_queue() do
        {:ok, slots} -> slots
        {:error, :no_sabnzbd_connection} -> nil
        {:error, _reason} -> "unavailable"
      end

    {:ok,
     %{
       catalog: Media.stats(),
       watches: Media.watch_stats(),
       recent_requests: requests,
       download_queue: downloads
     }}
  end

  def call("similar_media", args, _scope) do
    limit = int(args, key: "limit", default: 10, bounds: {1, 25})

    with {:ok, seed} <- resolve_seed(args) do
      case Media.similar_items_with_distance(seed, limit: limit) do
        [] when is_nil(seed.embedding) ->
          {:error, "#{seed.title} has no embedding yet — similarity unavailable for it"}

        neighbors ->
          {:ok,
           %{
             seed: %{id: seed.id, title: seed.title, kind: seed.kind},
             similar:
               Enum.map(neighbors, fn {item, distance} ->
                 item |> item_row() |> Map.put(:distance, Float.round(distance, 4))
               end)
           }}
      end
    end
  end

  def call(_name, _args, _scope), do: {:error, :unknown_tool}

  ## Shaping

  defp item_row(%Item{} = item) do
    %{
      id: item.id,
      kind: item.kind,
      title: item.title,
      year: item.year,
      status: item.status,
      genres: item.genres
    }
  end

  defp item_detail(%Item{} = item) do
    watchers =
      Media.item_watchers(item)
      |> Enum.map(fn {watch, user} ->
        %{
          user: handle(user),
          play_count: watch.play_count,
          last_played_at: watch.last_played_at,
          favorite: watch.favorite,
          liked: watch.liked,
          rating: watch.rating
        }
      end)

    item
    |> item_row()
    |> Map.merge(%{
      overview: item.overview,
      ratings: item.ratings,
      tmdb_id: item.tmdb_id,
      tvdb_id: item.tvdb_id,
      imdb_id: item.imdb_id,
      poster_url: item.poster_url,
      added_at: item.added_at,
      watchers: watchers
    })
  end

  defp lookup_new(kind, query) do
    case Integrations.list_connections(arr_for(kind)) do
      [] ->
        {:error, "no #{arr_for(kind)} connection configured — cannot look up new titles"}

      [connection | _rest] ->
        with {:ok, results} <- lookup(connection, query) do
          held = Media.held_provider_ids(kind)
          requested = Map.fetch!(Requests.requested_provider_ids(), String.to_existing_atom(kind))

          {:ok, results |> Enum.take(10) |> Enum.map(&candidate(&1, kind, held, requested))}
        end
    end
  end

  defp lookup(connection, query) do
    case ArrClient.lookup(connection, query) do
      {:ok, results} -> {:ok, results}
      {:error, reason} -> {:error, "#{connection.service} lookup failed: #{inspect(reason)}"}
    end
  end

  defp candidate(result, kind, held, requested) do
    tmdb_id = result["tmdbId"]
    tvdb_id = result["tvdbId"]
    provider_id = if kind == "movie", do: tmdb_id, else: tvdb_id

    %{
      kind: kind,
      title: result["title"],
      year: result["year"],
      tmdb_id: tmdb_id,
      tvdb_id: tvdb_id,
      poster_url: result["remotePoster"],
      in_library: present_in?(held.tmdb, tmdb_id) or present_in?(held.tvdb, tvdb_id),
      already_requested: present_in?(requested, provider_id)
    }
  end

  # The held/requested MapSets carry nils (movies have no tvdb id and
  # vice versa) — a nil candidate id must never match them.
  defp present_in?(_set, nil), do: false
  defp present_in?(set, id), do: MapSet.member?(set, id)

  defp resolve_seed(%{"id" => id}) when is_binary(id) do
    case Media.fetch_item(id) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, "no catalog item with id #{id}"}
    end
  end

  defp resolve_seed(%{"title" => title}) when is_binary(title) do
    case Media.search_items(q: title, presence: "all", per_page: 1) do
      %{items: [item | _rest]} -> {:ok, item}
      %{items: []} -> {:error, "no catalog item matching \"#{title}\""}
    end
  end

  defp resolve_seed(_args), do: {:error, "similar_media requires an id or a title"}

  defp require_kind(kind) when kind in ~w(movie series), do: {:ok, kind}
  defp require_kind(_), do: {:error, "include_new requires kind (movie or series)"}

  defp arr_for("movie"), do: "radarr"
  defp arr_for("series"), do: "sonarr"

  defp handle(user), do: user.email |> String.split("@") |> hd()

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp int(args, opts) do
    {min, max} = Keyword.fetch!(opts, :bounds)

    case args[Keyword.fetch!(opts, :key)] do
      value when is_integer(value) -> value |> max(min) |> min(max)
      _absent_or_invalid -> Keyword.fetch!(opts, :default)
    end
  end
end
