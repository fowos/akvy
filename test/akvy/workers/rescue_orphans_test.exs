defmodule Akvy.Workers.RescueOrphansTest do
  use Akvy.DataCase, async: true

  import Akvy.ConversionFixtures

  alias Akvy.{Heartbeat, Repo, Tasks}
  alias Akvy.Storage.Local
  alias Akvy.Workers.{Convert, RescueOrphans}

  # Puts the task's job into `executing` on the given producer, as if picked up long ago.
  defp start_attempt(task, producer_uuid, opts \\ []) do
    attempt = Keyword.get(opts, :attempt, 1)
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    attempted_at = DateTime.add(DateTime.utc_now(), -5, :minute)

    Repo.update_all(
      from(j in Oban.Job, where: j.worker == ^inspect(Convert)),
      set: [
        state: "executing",
        attempt: attempt,
        max_attempts: max_attempts,
        attempted_at: attempted_at,
        attempted_by: ["dead-node", producer_uuid]
      ]
    )

    {:ok, task, _} = Tasks.record(task, :attempt_started, attempt: attempt)
    task
  end

  defp job, do: Repo.one!(from j in Oban.Job, where: j.worker == ^inspect(Convert))

  defp event_types(task), do: task.id |> Tasks.list_events() |> Enum.map(& &1.type)

  test "retries a job whose instance stopped sending heartbeats" do
    task = task_fixture() |> start_attempt(Ecto.UUID.generate())

    assert :ok = perform_job(RescueOrphans, %{})

    assert %{state: "available", attempt: 1} = job()
    task = Tasks.get_task!(task.id)
    assert task.status == :retrying
    assert task.error == "instance dead-node stopped responding"
    assert Enum.take(event_types(task), -2) == [:attempt_failed, :retry_scheduled]
    assert Local.exists?(task.input_key)
  end

  test "fails the task when the lost attempt was the last one" do
    task = task_fixture() |> start_attempt(Ecto.UUID.generate(), attempt: 3, max_attempts: 3)

    assert :ok = perform_job(RescueOrphans, %{})

    assert %{state: "discarded"} = job()
    task = Tasks.get_task!(task.id)
    assert task.status == :failed
    refute Local.exists?(task.input_key)
  end

  test "leaves jobs of live instances alone" do
    producer = Ecto.UUID.generate()
    task = task_fixture() |> start_attempt(producer)
    Heartbeat.beat(Ecto.UUID.generate(), "live-node", producer)

    assert :ok = perform_job(RescueOrphans, %{})

    assert %{state: "executing"} = job()
    assert Tasks.get_task!(task.id).status == :processing
  end

  test "releases a download served by a dead instance" do
    task = completed_task_fixture()
    {:ok, task, _} = Tasks.start_download(task)
    old = DateTime.add(DateTime.utc_now(), -5, :minute)

    Repo.update_all(
      from(e in Akvy.Tasks.TaskEvent, where: e.task_id == ^task.id and e.seq == ^task.version),
      set: [occurred_at: old]
    )

    assert :ok = perform_job(RescueOrphans, %{})
    assert Tasks.get_task!(task.id).status == :completed
  end

  test "keeps a download served by a live instance" do
    Heartbeat.beat(Ecto.UUID.generate(), Akvy.Instance.id(), nil)
    task = completed_task_fixture()
    {:ok, task, _} = Tasks.start_download(task)

    assert :ok = perform_job(RescueOrphans, %{})
    assert Tasks.get_task!(task.id).status == :downloading
  end
end
