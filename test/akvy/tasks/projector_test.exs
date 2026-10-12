defmodule Akvy.Tasks.ProjectorTest do
  use ExUnit.Case, async: true

  alias Akvy.Tasks.{Projector, Task, TaskEvent}

  @t0 ~U[2026-10-12 10:00:00.000000Z]

  defp event(seq, type, offset_ms, opts \\ []) do
    %TaskEvent{
      seq: seq,
      type: type,
      attempt: Keyword.get(opts, :attempt, 1),
      node: "node-a",
      occurred_at: DateTime.add(@t0, offset_ms, :millisecond),
      duration_ms: Keyword.get(opts, :duration_ms),
      data: Keyword.get(opts, :data, %{})
    }
  end

  defp happy_path do
    [
      event(1, :uploaded, 0,
        attempt: 0,
        duration_ms: 400,
        data: %{"queue_id" => "q", "input_key" => "inputs/x", "input_size" => 100}
      ),
      event(2, :enqueued, 1, attempt: 0),
      event(3, :attempt_started, 1_000, duration_ms: 999),
      event(4, :s3_download_started, 1_010),
      event(5, :s3_download_finished, 6_010, duration_ms: 5_000),
      event(6, :ffmpeg_started, 6_020),
      event(7, :ffmpeg_finished, 21_020, duration_ms: 15_000, data: %{"exit_code" => 0}),
      event(8, :s3_upload_started, 21_030),
      event(9, :s3_upload_finished, 24_030,
        duration_ms: 3_000,
        data: %{"output_key" => "outputs/x.mp4", "output_size" => 50}
      ),
      event(10, :input_deleted, 24_100),
      event(11, :completed, 30_000, data: %{"expires_at" => "2026-10-13T10:00:30Z"})
    ]
  end

  test "replays the happy path into a completed snapshot with stage timings" do
    assert {:ok, task} = Projector.replay(happy_path(), %Task{id: "t"})

    assert task.status == :completed
    assert task.version == 11
    assert task.attempt == 1
    assert task.node == "node-a"
    assert task.upload_ms == 400
    assert task.queue_wait_ms == 999
    assert task.s3_download_ms == 5_000
    assert task.ffmpeg_ms == 15_000
    assert task.s3_upload_ms == 3_000
    assert task.processing_ms == 29_000
    assert task.total_ms == 30_000
    assert task.output_key == "outputs/x.mp4"
    assert task.input_deleted_at
    assert task.expires_at == ~U[2026-10-13 10:00:30Z]
  end

  test "download lifecycle" do
    {:ok, task} = Projector.replay(happy_path(), %Task{id: "t"})

    assert {:ok, task} = Projector.apply_event(task, event(12, :download_started, 40_000))
    assert task.status == :downloading
    assert {:ok, task} = Projector.apply_event(task, event(13, :download_aborted, 41_000))
    assert task.status == :completed
    assert {:ok, task} = Projector.apply_event(task, event(14, :download_started, 42_000))
    assert {:ok, task} = Projector.apply_event(task, event(15, :downloaded, 43_000))
    assert task.status == :downloaded
    assert task.downloaded_at
  end

  test "retry resets per-attempt timings" do
    events =
      Enum.take(happy_path(), 7) ++
        [
          event(8, :attempt_failed, 21_100, data: %{"error" => "boom", "exit_code" => 1}),
          event(9, :retry_scheduled, 21_200),
          event(10, :attempt_started, 40_000, attempt: 2, duration_ms: 100)
        ]

    assert {:ok, task} = Projector.replay(events, %Task{id: "t"})
    assert task.status == :processing
    assert task.attempt == 2
    assert task.ffmpeg_ms == nil
    assert task.error == nil
  end

  test "rejects invalid transitions" do
    {:ok, task} = Projector.replay(happy_path(), %Task{id: "t"})

    assert {:error, {:invalid_transition, :completed, :attempt_started}} =
             Projector.project(task, event(12, :attempt_started, 50_000))

    assert {:error, {:invalid_transition, :completed, :input_deleted}} =
             Projector.project(task, event(12, :input_deleted, 50_000))
  end

  test "failed tasks keep the last error" do
    events =
      Enum.take(happy_path(), 7) ++
        [
          event(8, :attempt_failed, 21_100, data: %{"error" => "ffmpeg exited with status 1"}),
          event(9, :failed, 21_200, data: %{"error" => "ffmpeg exited with status 1"})
        ]

    assert {:ok, task} = Projector.replay(events, %Task{id: "t"})
    assert task.status == :failed
    assert task.error == "ffmpeg exited with status 1"
    assert task.finished_at
  end
end
