defmodule MediaAssist.Media.EmbedWorker do
  @moduledoc """
  Embeds every unembedded media item through the AI gateway's embedding
  model, in batches, until the index is covered. Enqueued by
  `Media.SyncWorker` when `embed_on_sync` is set (and safe to enqueue
  directly). Unique while queued/executing so repeated syncs don't stack
  duplicate jobs.

  A gateway error fails the job and lets Oban retry; a disabled gateway
  is a clean no-op so syncs never fail on a missing configuration.
  """

  use Oban.Worker,
    queue: :indexer,
    max_attempts: 3,
    unique: [period: 60, states: Oban.Job.states() -- [:completed, :discarded, :cancelled]]

  require Logger

  alias MediaAssist.AI.Gateway
  alias MediaAssist.Media

  @batch_size 32
  # Backstop far above any real index size (100 * 32 = 3200 items/run).
  @max_batches 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Gateway.configured?() do
      embed_batches(0, 0)
    else
      Logger.info("embed: gateway not configured — skipping")
      :ok
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  defp embed_batches(embedded, batch) when batch >= @max_batches do
    Logger.warning("embed: stopped at batch cap with #{embedded} embedded")
    :ok
  end

  defp embed_batches(embedded, batch) do
    case Media.list_unembedded_items(@batch_size) do
      [] ->
        Logger.info("embed: complete — #{embedded} items embedded this run")
        :ok

      items ->
        with {:ok, vectors} <- embed_texts(Enum.map(items, &Media.embedding_text/1)) do
          items
          |> Enum.zip(vectors)
          |> Enum.each(fn {item, vector} -> Media.put_embedding(item, vector) end)

          embed_batches(embedded + length(items), batch + 1)
        end
    end
  end

  defp embed_texts(texts) do
    case Gateway.embed(texts) do
      {:ok, %{"data" => data}} when length(data) == length(texts) ->
        {:ok, data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
