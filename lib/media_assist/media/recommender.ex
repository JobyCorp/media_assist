defmodule MediaAssist.Media.Recommender do
  @moduledoc """
  Personal recommendations from the vector graph, v1: embedding
  neighbors of the user's recent watches.

  Each of the user's most recent watches seeds a nearest-neighbor
  lookup; candidates accumulate `similarity × recency-decay` across
  seeds, already-watched titles are excluded, and each result keeps its
  strongest seed as the human-readable reason ("because you watched X").
  Graph edges join the scoring as the edge layer grows.

  Users with no watch history fall back to recently added titles.
  """

  alias MediaAssist.Accounts.User
  alias MediaAssist.Media

  @seed_count 15
  @neighbors_per_seed 12
  @recency_decay 0.9

  @doc """
  Returns `%{recommendations: [...], source: :watches | :recently_added}`.
  Each recommendation is `%{item, reason, match}` (match is 0–100).
  """
  def for_user(user_or_nil, opts \\ [])

  def for_user(%User{} = user, opts) do
    limit = Keyword.get(opts, :limit, 8)
    seeds = Media.list_watched_items(user, limit: @seed_count)

    case seeds do
      [] ->
        fallback(limit)

      seeds ->
        watched = MapSet.new(Media.watched_item_ids(user))

        recommendations =
          seeds
          |> score_candidates(watched)
          |> Enum.take(limit)

        %{recommendations: recommendations, source: :watches}
    end
  end

  def for_user(nil, opts), do: fallback(Keyword.get(opts, :limit, 8))

  defp fallback(limit) do
    recommendations =
      for item <- Media.recently_added(limit) do
        %{item: item, reason: "new in the library", match: nil}
      end

    %{recommendations: recommendations, source: :recently_added}
  end

  @favorite_boost 1.5

  # A thumbs-down or a low explicit rating is an anti-signal.
  defp anti_signal?(watch), do: watch.liked == false or (watch.rating || 10) <= 4

  # A heart or a high explicit rating means "loved", not just "watched".
  defp loved?(watch), do: watch.favorite or (watch.rating || 0) >= 9

  defp score_candidates(seeds, watched) do
    seeds
    |> Enum.reject(fn {watch, _seed} -> anti_signal?(watch) end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{watch, seed}, index} ->
      decay = :math.pow(@recency_decay, index)
      boost = if loved?(watch), do: @favorite_boost, else: 1.0

      seed
      |> Media.similar_items_with_distance(limit: @neighbors_per_seed, statuses: ["in_library"])
      |> Enum.reject(fn {item, _distance} -> MapSet.member?(watched, item.id) end)
      |> Enum.map(fn {item, distance} ->
        similarity = 1.0 - distance

        %{
          item: item,
          seed: seed,
          favorite_seed: loved?(watch),
          similarity: similarity,
          score: similarity * decay * boost
        }
      end)
    end)
    |> Enum.group_by(& &1.item.id)
    |> Enum.map(fn {_id, entries} ->
      best = Enum.max_by(entries, & &1.similarity)
      verb = if best.favorite_seed, do: "loved", else: "watched"

      %{
        item: best.item,
        reason: ~s(because you #{verb} #{best.seed.title}),
        match: round(best.similarity * 100),
        score: entries |> Enum.map(& &1.score) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.map(&Map.delete(&1, :score))
  end
end
