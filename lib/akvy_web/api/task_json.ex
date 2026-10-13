defmodule AkvyWeb.Api.TaskJSON do
  @moduledoc "Renders tasks and SSE snapshots for the client API."
  use AkvyWeb, :verified_routes

  alias Akvy.Tasks.Task

  @typedoc "Durations of the last attempt, in milliseconds."
  @type timings :: %{
          upload_ms: non_neg_integer() | nil,
          queue_wait_ms: non_neg_integer() | nil,
          s3_download_ms: non_neg_integer() | nil,
          ffmpeg_ms: non_neg_integer() | nil,
          s3_upload_ms: non_neg_integer() | nil,
          processing_ms: non_neg_integer() | nil,
          total_ms: non_neg_integer() | nil
        }

  @type links :: %{self: String.t(), events: String.t(), result: String.t()}

  @type task_json :: %{
          id: UUIDv7.t(),
          queue_id: UUIDv7.t(),
          status: Task.status(),
          attempt: non_neg_integer(),
          original_filename: String.t() | nil,
          content_type: String.t() | nil,
          input_size: non_neg_integer() | nil,
          output_size: non_neg_integer() | nil,
          error: String.t() | nil,
          uploaded_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          downloaded_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          timings: timings(),
          links: links()
        }

  @typedoc "SSE event data: `t:Akvy.Tasks.payload/0` without `api_key_id`."
  @type event_json :: %{
          id: UUIDv7.t(),
          queue_id: UUIDv7.t(),
          status: String.t(),
          event: String.t(),
          seq: non_neg_integer(),
          attempt: non_neg_integer(),
          occurred_at: String.t(),
          duration_ms: non_neg_integer() | nil,
          error: String.t() | nil,
          output_size: non_neg_integer() | nil,
          expires_at: String.t() | nil
        }

  @doc "Renders a page of tasks with the cursor of the next page."
  @spec index(%{tasks: [Task.t()], next_cursor: UUIDv7.t() | nil}) ::
          %{data: [task_json()], next_cursor: UUIDv7.t() | nil}
  def index(%{tasks: tasks, next_cursor: cursor}) do
    %{data: Enum.map(tasks, &data/1), next_cursor: cursor}
  end

  @doc "Renders a single task."
  @spec show(%{task: Task.t()}) :: %{data: task_json()}
  def show(%{task: task}), do: %{data: data(task)}

  @doc "Renders the JSON representation of a task."
  @spec data(Task.t()) :: task_json()
  def data(%Task{} = task) do
    %{
      id: task.id,
      queue_id: task.queue_id,
      status: task.status,
      attempt: task.attempt,
      original_filename: task.original_filename,
      content_type: task.content_type,
      input_size: task.input_size,
      output_size: task.output_size,
      error: task.error,
      uploaded_at: task.uploaded_at,
      started_at: task.started_at,
      finished_at: task.finished_at,
      downloaded_at: task.downloaded_at,
      expires_at: task.expires_at,
      timings: %{
        upload_ms: task.upload_ms,
        queue_wait_ms: task.queue_wait_ms,
        s3_download_ms: task.s3_download_ms,
        ffmpeg_ms: task.ffmpeg_ms,
        s3_upload_ms: task.s3_upload_ms,
        processing_ms: task.processing_ms,
        total_ms: task.total_ms
      },
      links: %{
        self: ~p"/api/v1/tasks/#{task.id}",
        events: ~p"/api/v1/tasks/#{task.id}/events",
        result: ~p"/api/v1/tasks/#{task.id}/result"
      }
    }
  end

  @doc "Snapshot message sent as the first SSE event of a per-task stream."
  @spec snapshot_event(Task.t()) :: event_json()
  def snapshot_event(%Task{} = task) do
    %{
      id: task.id,
      queue_id: task.queue_id,
      status: to_string(task.status),
      event: "snapshot",
      seq: task.version,
      attempt: task.attempt,
      occurred_at: DateTime.to_iso8601(task.updated_at),
      duration_ms: nil,
      error: task.error,
      output_size: task.output_size,
      expires_at: task.expires_at && DateTime.to_iso8601(task.expires_at)
    }
  end
end
