defmodule Akvy.Tasks.Projector do
  @moduledoc """
  Pure projection of task events onto the task snapshot.

  `project/2` validates that the event is allowed in the current status and
  returns the snapshot field changes. The same function is used for live writes
  and for rebuilding a snapshot from history, so both always agree.
  """
  alias Akvy.Tasks.{Task, TaskEvent}

  @processing_from [:uploaded, :retrying, :processing]
  @cancellable [:uploaded, :retrying, :processing, :completed]

  @typedoc "Snapshot field changes produced by an event."
  @type changes :: %{optional(atom()) => term()}

  @type invalid_transition :: {:invalid_transition, Task.status() | nil, TaskEvent.type()}

  @doc "Returns `{:ok, changes}` or `{:error, {:invalid_transition, status, type}}`."
  @spec project(Task.t(), TaskEvent.t()) :: {:ok, changes()} | {:error, invalid_transition()}
  def project(%Task{} = task, %TaskEvent{} = event) do
    case changes(task.status, task, event) do
      {:ok, changes} -> {:ok, Map.put(changes, :version, event.seq)}
      :error -> {:error, {:invalid_transition, task.status, event.type}}
    end
  end

  @doc "Applies the event to the struct (used when replaying history)."
  @spec apply_event(Task.t(), TaskEvent.t()) :: {:ok, Task.t()} | {:error, invalid_transition()}
  def apply_event(%Task{} = task, %TaskEvent{} = event) do
    with {:ok, changes} <- project(task, event) do
      {:ok, struct(task, changes)}
    end
  end

  @doc "Rebuilds a snapshot by folding over the events ordered by `seq`."
  @spec replay(Enumerable.t(TaskEvent.t()), Task.t()) ::
          {:ok, Task.t()} | {:error, invalid_transition()}
  def replay(events, %Task{} = base \\ %Task{}) do
    Enum.reduce_while(events, {:ok, base}, fn event, {:ok, task} ->
      case apply_event(task, event) do
        {:ok, task} -> {:cont, {:ok, task}}
        error -> {:halt, error}
      end
    end)
  end

  @spec changes(Task.status() | nil, Task.t(), TaskEvent.t()) :: {:ok, changes()} | :error
  defp changes(nil, _task, %{type: :uploaded} = e) do
    {:ok,
     %{
       status: :uploaded,
       queue_id: data(e, "queue_id"),
       api_key_id: data(e, "api_key_id"),
       original_filename: data(e, "original_filename"),
       content_type: data(e, "content_type"),
       input_key: data(e, "input_key"),
       input_size: data(e, "input_size"),
       uploaded_at: e.occurred_at,
       upload_ms: e.duration_ms
     }}
  end

  defp changes(status, _task, %{type: :enqueued} = e) when status in [:uploaded, :retrying],
    do: {:ok, %{job_id: data(e, "job_id")}}

  defp changes(status, _task, %{type: :attempt_started} = e) when status in @processing_from do
    {:ok,
     %{
       status: :processing,
       attempt: e.attempt,
       node: e.node,
       started_at: e.occurred_at,
       queue_wait_ms: e.duration_ms,
       s3_download_ms: nil,
       ffmpeg_ms: nil,
       s3_upload_ms: nil,
       exit_code: nil,
       error: nil
     }}
  end

  defp changes(:processing, _task, %{type: type})
       when type in [:s3_download_started, :ffmpeg_started, :s3_upload_started],
       do: {:ok, %{}}

  defp changes(:processing, _task, %{type: :s3_download_finished} = e),
    do: {:ok, %{s3_download_ms: e.duration_ms}}

  defp changes(:processing, _task, %{type: :ffmpeg_finished} = e),
    do: {:ok, %{ffmpeg_ms: e.duration_ms, exit_code: data(e, "exit_code")}}

  defp changes(:processing, _task, %{type: :s3_upload_finished} = e) do
    {:ok,
     %{
       s3_upload_ms: e.duration_ms,
       output_key: data(e, "output_key"),
       output_size: data(e, "output_size")
     }}
  end

  defp changes(:processing, _task, %{type: :attempt_failed} = e),
    do: {:ok, %{error: data(e, "error"), exit_code: data(e, "exit_code")}}

  defp changes(:processing, _task, %{type: :retry_scheduled}), do: {:ok, %{status: :retrying}}

  defp changes(:processing, task, %{type: :completed} = e) do
    {:ok,
     %{
       status: :completed,
       finished_at: e.occurred_at,
       expires_at: parse_datetime(data(e, "expires_at")),
       processing_ms: diff_ms(e.occurred_at, task.started_at),
       total_ms: diff_ms(e.occurred_at, task.uploaded_at),
       error: nil
     }}
  end

  defp changes(status, task, %{type: :failed} = e) when status in @processing_from do
    {:ok,
     %{
       status: :failed,
       finished_at: e.occurred_at,
       error: data(e, "error") || task.error,
       processing_ms: diff_ms(e.occurred_at, task.started_at),
       total_ms: diff_ms(e.occurred_at, task.uploaded_at)
     }}
  end

  defp changes(status, _task, %{type: :cancelled} = e) when status in @cancellable,
    do: {:ok, %{status: :cancelled, finished_at: e.occurred_at}}

  defp changes(:completed, _task, %{type: :download_started}), do: {:ok, %{status: :downloading}}

  defp changes(:downloading, _task, %{type: :download_aborted}), do: {:ok, %{status: :completed}}

  defp changes(:downloading, _task, %{type: :downloaded} = e),
    do: {:ok, %{status: :downloaded, downloaded_at: e.occurred_at}}

  defp changes(:completed, _task, %{type: :expired}), do: {:ok, %{status: :expired}}

  defp changes(status, %{input_deleted_at: nil}, %{type: :input_deleted} = e)
       when not is_nil(status),
       do: {:ok, %{input_deleted_at: e.occurred_at}}

  defp changes(status, %{output_deleted_at: nil}, %{type: :output_deleted} = e)
       when not is_nil(status),
       do: {:ok, %{output_deleted_at: e.occurred_at}}

  defp changes(_status, _task, _event), do: :error

  defp data(%{data: data}, key), do: Map.get(data || %{}, key)

  defp diff_ms(_to, nil), do: nil
  defp diff_ms(to, from), do: DateTime.diff(to, from, :millisecond)

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
