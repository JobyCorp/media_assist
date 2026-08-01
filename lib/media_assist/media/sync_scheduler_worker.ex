defmodule MediaAssist.Media.SyncSchedulerWorker do
  @moduledoc """
  Cron-driven tick (see the Oban config) that makes `sync_interval_minutes`
  real: when `last_synced_at` is missing or older than the configured
  interval, a `Media.SyncWorker` is enqueued. Manual syncs stamp
  `last_synced_at` too, so they push the next automatic run out.

  The tick runs far more often than any allowed interval; the check here
  is what spaces actual syncs.
  """

  use Oban.Worker,
    queue: :indexer,
    max_attempts: 1,
    unique: [period: :infinity, states: Oban.Job.states() -- [:completed, :discarded, :cancelled]]

  require Logger

  alias MediaAssist.Integrations

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    settings = Integrations.get_index_settings()

    if due?(settings.last_synced_at, settings.sync_interval_minutes) do
      Logger.info("sync scheduler: interval elapsed — enqueuing media sync")
      Oban.insert(MediaAssist.Media.SyncWorker.new(%{}))
    end

    :ok
  end

  defp due?(nil, _interval_minutes), do: true

  defp due?(last_synced_at, interval_minutes) do
    DateTime.diff(DateTime.utc_now(), last_synced_at, :minute) >= interval_minutes
  end
end
