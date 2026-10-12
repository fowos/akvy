defmodule Akvy.Workers.ConvertTest do
  use Akvy.DataCase, async: true

  import Akvy.ConversionFixtures

  alias Akvy.FakeFFmpeg
  alias Akvy.Storage.Local
  alias Akvy.Tasks
  alias Akvy.Workers.Convert

  defp event_types(task), do: task.id |> Tasks.list_events() |> Enum.map(& &1.type)

  test "converts the file and records every stage" do
    task = task_fixture()

    assert :ok = perform_job(Convert, %{"task_id" => task.id}, attempt: 1, max_attempts: 2)

    task = Tasks.get_task!(task.id)
    assert task.status == :completed
    assert task.attempt == 1
    assert is_integer(task.s3_download_ms)
    assert is_integer(task.ffmpeg_ms)
    assert is_integer(task.s3_upload_ms)
    assert is_integer(task.total_ms)
    assert task.output_size > 0
    assert task.expires_at
    assert Local.exists?(task.output_key)
    refute Local.exists?(task.input_key)

    assert event_types(task) == [
             :uploaded,
             :enqueued,
             :attempt_started,
             :s3_download_started,
             :s3_download_finished,
             :ffmpeg_started,
             :ffmpeg_finished,
             :s3_upload_started,
             :s3_upload_finished,
             :input_deleted,
             :completed
           ]

    messages = task.id |> Tasks.list_logs() |> Enum.map(& &1.message)
    assert String.starts_with?(hd(messages), "ffmpeg ")
    assert "video:1kB audio:0kB muxing overhead: 0%" in messages
  end

  test "keeps the source and schedules a retry when an attempt fails" do
    task = task_fixture()
    FakeFFmpeg.set_mode(:fail)

    assert {:error, "ffmpeg exited with status 1"} =
             perform_job(Convert, %{"task_id" => task.id}, attempt: 1, max_attempts: 2)

    task = Tasks.get_task!(task.id)
    assert task.status == :retrying
    assert task.exit_code == 1
    assert task.error == "ffmpeg exited with status 1"
    assert Local.exists?(task.input_key)

    FakeFFmpeg.set_mode(:ok)
    assert :ok = perform_job(Convert, %{"task_id" => task.id}, attempt: 2, max_attempts: 2)

    task = Tasks.get_task!(task.id)
    assert task.status == :completed
    assert task.attempt == 2
    assert task.error == nil
  end

  test "fails the task and deletes the source after the last attempt" do
    task = task_fixture()
    FakeFFmpeg.set_mode(:timeout)

    assert {:cancel, "ffmpeg timed out after 60s"} =
             perform_job(Convert, %{"task_id" => task.id}, attempt: 2, max_attempts: 2)

    task = Tasks.get_task!(task.id)
    assert task.status == :failed
    assert task.input_deleted_at
    refute Local.exists?(task.input_key)
    assert :failed in event_types(task)
  end

  test "fails when ffmpeg produces no output" do
    task = task_fixture()
    FakeFFmpeg.set_mode(:no_output)

    assert {:cancel, "ffmpeg produced no output file"} =
             perform_job(Convert, %{"task_id" => task.id}, attempt: 1, max_attempts: 1)
  end

  test "does nothing for cancelled tasks" do
    task = task_fixture()
    {:ok, task} = Tasks.cancel_task(task)

    assert {:cancel, {:unexpected_status, :cancelled}} =
             perform_job(Convert, %{"task_id" => task.id})
  end
end
