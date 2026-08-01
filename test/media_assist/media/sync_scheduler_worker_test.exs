defmodule MediaAssist.Media.SyncSchedulerWorkerTest do
  use MediaAssist.DataCase, async: true
  use Oban.Testing, repo: MediaAssist.Repo

  alias MediaAssist.Integrations
  alias MediaAssist.Media.SyncSchedulerWorker
  alias MediaAssist.Media.SyncWorker

  test "enqueues a sync when there has never been one" do
    assert :ok = perform_job(SyncSchedulerWorker, %{})
    assert_enqueued(worker: SyncWorker)
  end

  test "enqueues a sync when the interval has elapsed" do
    {:ok, _settings} = Integrations.update_index_settings(%{sync_interval_minutes: 60})
    stamp_last_synced(minutes_ago: 61)

    assert :ok = perform_job(SyncSchedulerWorker, %{})
    assert_enqueued(worker: SyncWorker)
  end

  test "does nothing while the interval has not elapsed" do
    {:ok, _settings} = Integrations.update_index_settings(%{sync_interval_minutes: 360})
    stamp_last_synced(minutes_ago: 30)

    assert :ok = perform_job(SyncSchedulerWorker, %{})
    refute_enqueued(worker: SyncWorker)
  end

  defp stamp_last_synced(minutes_ago: minutes) do
    Integrations.get_index_settings()
    |> Ecto.Changeset.change(
      last_synced_at: DateTime.utc_now(:second) |> DateTime.add(-minutes, :minute)
    )
    |> Repo.insert_or_update!()
  end
end
