defmodule Akvy.Workers.Convert do
  @moduledoc """
  Converts a single task: S3 download -> ffmpeg -> S3 upload.

  Every stage is recorded as a pair of `*_started` / `*_finished` events with
  `duration_ms`, so the admin panel can show exactly where time was spent.
  On failure the source file is kept for retries and deleted after the last attempt.
  """
  use Oban.Worker, queue: :convert, max_attempts: 3

  require Logger

  alias Akvy.{FFmpeg, Queues, Storage, Tasks}
  alias Akvy.Tasks.{LogBuffer, Task}

  # Extra time on top of the ffmpeg timeout for S3 transfers.
  @transfer_allowance_ms :timer.minutes(30)

  @impl Oban.Worker
  def timeout(%Oban.Job{meta: %{"timeout_ms" => timeout_ms}}),
    do: timeout_ms + @transfer_allowance_ms

  def timeout(_job), do: :infinity

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}} = job) do
    case Tasks.get_task(task_id) do
      nil ->
        {:cancel, :task_not_found}

      %Task{status: status} = task when status in [:uploaded, :retrying, :processing] ->
        queue = Queues.get_queue!(task.queue_id)
        run(task, queue, job)

      %Task{status: status} ->
        {:cancel, {:unexpected_status, status}}
    end
  end

  @spec run(Task.t(), Akvy.Queues.Queue.t(), Oban.Job.t()) ::
          :ok | {:error, String.t()} | {:cancel, term()}
  defp run(task, queue, job) do
    work_dir = Path.join(Application.fetch_env!(:akvy, :work_dir), "#{task.id}-#{job.attempt}")
    File.mkdir_p!(work_dir)

    try do
      wait_ms = queue_wait_ms(job)
      task = record!(task, :attempt_started, attempt: job.attempt, duration_ms: wait_ms)
      logs = LogBuffer.new(task.id, job.attempt)

      {task, logs} = convert(task, queue, work_dir, logs)

      # A failed cleanup is retried by Akvy.Workers.ExpireFiles; it must not fail the task.
      {task, logs} =
        case Tasks.delete_input(task) do
          {:ok, task} ->
            {task, logs}

          {:error, reason} ->
            {task,
             LogBuffer.add(logs, :worker, :warning, "input cleanup failed: #{inspect(reason)}")}
        end

      LogBuffer.flush(logs)

      expires_at = DateTime.add(DateTime.utc_now(), queue.result_ttl_seconds, :second)
      record!(task, :completed, data: %{"expires_at" => DateTime.to_iso8601(expires_at)})
      :ok
    catch
      {:stage_failed, task, logs, reason, data} ->
        LogBuffer.flush(logs)
        handle_failure(task, job, reason, data)

      {:abort, reason} ->
        {:cancel, reason}
    after
      File.rm_rf(work_dir)
    end
  end

  @spec convert(Task.t(), Akvy.Queues.Queue.t(), Path.t(), LogBuffer.t()) ::
          {Task.t(), LogBuffer.t()}
  defp convert(task, queue, work_dir, logs) do
    input_path = Path.join(work_dir, "input")
    output_path = Path.join(work_dir, "output.#{queue.output_extension}")

    # 1. S3 -> local
    task = record!(task, :s3_download_started)
    {ms, result} = Tasks.timed(fn -> Storage.download_to(task.input_key, input_path) end)

    if result != :ok do
      fail!(task, logs, "S3 download failed: #{inspect(result)}", %{"stage" => "s3_download"})
    end

    task =
      record!(task, :s3_download_finished,
        duration_ms: ms,
        data: %{"bytes" => file_size(input_path)}
      )

    # 2. ffmpeg
    {:ok, argv} = FFmpeg.build_argv(queue.ffmpeg_args, input_path, output_path)
    task = record!(task, :ffmpeg_started, data: %{"argv" => argv})
    logs = LogBuffer.add(logs, :worker, :info, "ffmpeg " <> Enum.join(argv, " "))

    {ms, result} =
      Tasks.timed(fn ->
        FFmpeg.run(argv,
          timeout: queue.timeout_seconds * 1000,
          acc: logs,
          on_line: fn line, logs -> LogBuffer.add(logs, :ffmpeg, :info, line) end
        )
      end)

    {task, logs} =
      case result do
        {:ok, logs} ->
          {record!(task, :ffmpeg_finished, duration_ms: ms, data: %{"exit_code" => 0}), logs}

        {:error, {:exit_status, code}, logs} ->
          task =
            record!(task, :ffmpeg_finished, duration_ms: ms, data: %{"exit_code" => code})

          fail!(task, logs, "ffmpeg exited with status #{code}", %{
            "stage" => "ffmpeg",
            "exit_code" => code
          })

        {:error, :timeout, logs} ->
          task = record!(task, :ffmpeg_finished, duration_ms: ms, data: %{"timeout" => true})

          fail!(task, logs, "ffmpeg timed out after #{queue.timeout_seconds}s", %{
            "stage" => "ffmpeg"
          })

        {:error, :not_found, logs} ->
          fail!(task, logs, "ffmpeg executable not found", %{"stage" => "ffmpeg"})
      end

    unless File.exists?(output_path) do
      fail!(task, logs, "ffmpeg produced no output file", %{"stage" => "ffmpeg"})
    end

    # 3. local -> S3
    output_key = "outputs/#{task.id}.#{queue.output_extension}"
    task = record!(task, :s3_upload_started)

    {ms, result} =
      Tasks.timed(fn ->
        Storage.put_file(output_key, output_path, content_type: queue.output_content_type)
      end)

    if result != :ok do
      fail!(task, logs, "S3 upload failed: #{inspect(result)}", %{"stage" => "s3_upload"})
    end

    task =
      record!(task, :s3_upload_finished,
        duration_ms: ms,
        data: %{"output_key" => output_key, "output_size" => file_size(output_path)}
      )

    {task, logs}
  end

  @spec handle_failure(Task.t(), Oban.Job.t(), String.t(), map()) ::
          {:error, String.t()} | {:cancel, String.t()}
  defp handle_failure(task, job, reason, data) do
    data = Map.put(data, "error", reason)
    task = record!(task, :attempt_failed, data: data)

    if job.attempt < job.max_attempts do
      record!(task, :retry_scheduled, data: %{"next_attempt" => job.attempt + 1})
      {:error, reason}
    else
      task = record!(task, :failed, data: %{"error" => reason})

      case Tasks.delete_input(task) do
        {:ok, _} ->
          :ok

        {:error, error} ->
          Logger.warning("input cleanup failed for #{task.id}: #{inspect(error)}")
      end

      {:cancel, reason}
    end
  end

  @spec fail!(Task.t(), LogBuffer.t(), String.t(), map()) :: no_return()
  defp fail!(task, logs, reason, data) do
    logs = LogBuffer.add(logs, :worker, :error, reason)
    throw({:stage_failed, task, logs, reason, data})
  end

  # Any write conflict means the task was changed elsewhere (e.g. cancelled):
  # stop processing instead of overwriting.
  @spec record!(Task.t(), Akvy.Tasks.TaskEvent.type(), keyword()) :: Task.t()
  defp record!(task, type, opts \\ []) do
    case Tasks.record(task, type, opts) do
      {:ok, task, _event} -> task
      {:error, reason} -> throw({:abort, {:task_changed, type, reason}})
    end
  end

  @spec queue_wait_ms(Oban.Job.t()) :: non_neg_integer() | nil
  defp queue_wait_ms(%Oban.Job{
         attempted_at: %DateTime{} = at,
         scheduled_at: %DateTime{} = sched
       }),
       do: max(DateTime.diff(at, sched, :millisecond), 0)

  defp queue_wait_ms(_job), do: nil

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end
end
