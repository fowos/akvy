defmodule Akvy.ShutdownTest do
  # Toggles the global draining flag.
  use AkvyWeb.ConnCase, async: false

  import Akvy.ConversionFixtures
  import Ecto.Query

  alias Akvy.{Recovery, Repo, Shutdown, Tasks}
  alias Akvy.Shutdown.JobDrain
  alias Akvy.Workers.Convert

  defp job, do: Repo.one!(from j in Oban.Job, where: j.worker == ^inspect(Convert))

  test "a handed-over conversion goes back to the queue without spending an attempt" do
    task = task_fixture()

    Repo.update_all(Oban.Job,
      set: [
        state: "executing",
        attempt: 3,
        max_attempts: 3,
        attempted_at: DateTime.utc_now(),
        attempted_by: ["this-node", Ecto.UUID.generate()]
      ]
    )

    {:ok, task, _} = Tasks.record(task, :attempt_started, attempt: 3)

    assert :ok = Recovery.release_job(job(), "instance shut down", refund_attempt: true)

    assert %{state: "available", attempt: 2} = job()
    task = Tasks.get_task!(task.id)
    assert task.status == :retrying
    assert task.error == "instance shut down"
  end

  test "downloads served by this instance are released" do
    task = completed_task_fixture()
    {:ok, task, _} = Tasks.start_download(task)

    assert :ok = JobDrain.release_downloads("instance shut down")
    assert Tasks.get_task!(task.id).status == :completed
  end

  test "/health reports draining while shutting down", %{conn: conn} do
    on_exit(fn -> :persistent_term.erase({Shutdown, :draining}) end)

    assert %{"status" => "ok"} = conn |> get(~p"/health") |> json_response(200)

    Shutdown.mark_draining()
    assert %{"status" => "draining"} = build_conn() |> get(~p"/health") |> json_response(503)
  end
end
