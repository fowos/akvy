defmodule Akvy.Workers.MaintenanceTest do
  use Akvy.DataCase, async: true

  import Akvy.ConversionFixtures

  alias Akvy.Repo
  alias Akvy.Storage.Local
  alias Akvy.Tasks
  alias Akvy.Tasks.{Task, TaskLog}
  alias Akvy.Workers.{ExpireFiles, PruneLogs}

  test "ExpireFiles deletes results that were not downloaded in time" do
    task = completed_task_fixture()
    fresh = completed_task_fixture()

    past = DateTime.add(DateTime.utc_now(), -60, :second)
    Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [expires_at: past])

    assert :ok = perform_job(ExpireFiles, %{})

    task = Tasks.get_task!(task.id)
    assert task.status == :expired
    assert task.output_deleted_at
    refute Local.exists?(task.output_key)

    assert Tasks.get_task!(fresh.id).status == :completed
    assert Local.exists?(fresh.output_key)
  end

  test "ExpireFiles fails tasks whose job disappeared" do
    task = task_fixture()
    old = DateTime.add(DateTime.utc_now(), -2, :hour)
    Repo.delete_all(Oban.Job)
    Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [updated_at: old])

    assert :ok = perform_job(ExpireFiles, %{})

    task = Tasks.get_task!(task.id)
    assert task.status == :failed
    assert task.error == "conversion job lost"
    refute Local.exists?(task.input_key)
  end

  test "PruneLogs removes logs older than the queue retention" do
    queue = queue_fixture(%{log_retention_days: 1})
    task = completed_task_fixture(queue)
    assert Repo.aggregate(from(l in TaskLog, where: l.task_id == ^task.id), :count) > 0

    old = DateTime.add(DateTime.utc_now(), -2, :day)
    Repo.update_all(from(l in TaskLog, where: l.task_id == ^task.id), set: [inserted_at: old])

    assert :ok = perform_job(PruneLogs, %{})
    assert Repo.aggregate(from(l in TaskLog, where: l.task_id == ^task.id), :count) == 0
    # history is kept
    assert Tasks.list_events(task.id) != []
  end
end
