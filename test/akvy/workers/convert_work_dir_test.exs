defmodule Akvy.Workers.ConvertWorkDirTest do
  # Changes the global :work_dir, so it cannot run concurrently with other tests.
  use Akvy.DataCase, async: false

  import Akvy.ConversionFixtures

  alias Akvy.Tasks
  alias Akvy.Workers.Convert

  setup do
    original = Application.fetch_env!(:akvy, :work_dir)
    # A regular file as the parent makes mkdir fail on every OS.
    blocker = Path.join(System.tmp_dir!(), "akvy_blocker_#{System.unique_integer([:positive])}")
    File.write!(blocker, "")
    Application.put_env(:akvy, :work_dir, Path.join(blocker, "work"))

    on_exit(fn ->
      Application.put_env(:akvy, :work_dir, original)
      File.rm(blocker)
    end)
  end

  test "an unusable work dir schedules a retry instead of crashing" do
    task = task_fixture()

    assert {:error, "cannot create " <> _} =
             perform_job(Convert, %{"task_id" => task.id}, attempt: 1, max_attempts: 2)

    assert Tasks.get_task!(task.id).status == :retrying
  end

  test "an unusable work dir fails the task on the last attempt" do
    task = task_fixture()

    assert {:cancel, "cannot create " <> _} =
             perform_job(Convert, %{"task_id" => task.id}, attempt: 2, max_attempts: 2)

    task = Tasks.get_task!(task.id)
    assert task.status == :failed
    assert task.error =~ "cannot create"
  end
end
