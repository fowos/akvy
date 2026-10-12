defmodule Akvy.Tasks.TaskEvent do
  @moduledoc """
  Append-only history entry of a task. `seq` is a per-task sequence number that
  equals the snapshot `version` after the event has been applied.
  """
  use Akvy.Schema

  # Stored as smallint. Codes must never change; add new types with new codes.
  @types [
    uploaded: 1,
    enqueued: 2,
    attempt_started: 3,
    s3_download_started: 4,
    s3_download_finished: 5,
    ffmpeg_started: 6,
    ffmpeg_finished: 7,
    s3_upload_started: 8,
    s3_upload_finished: 9,
    attempt_failed: 10,
    retry_scheduled: 11,
    completed: 12,
    failed: 13,
    input_deleted: 14,
    download_started: 15,
    download_aborted: 16,
    downloaded: 17,
    output_deleted: 18,
    expired: 19,
    cancelled: 20
  ]

  @type type ::
          :uploaded
          | :enqueued
          | :attempt_started
          | :s3_download_started
          | :s3_download_finished
          | :ffmpeg_started
          | :ffmpeg_finished
          | :s3_upload_started
          | :s3_upload_finished
          | :attempt_failed
          | :retry_scheduled
          | :completed
          | :failed
          | :input_deleted
          | :download_started
          | :download_aborted
          | :downloaded
          | :output_deleted
          | :expired
          | :cancelled

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          seq: pos_integer() | nil,
          type: type() | nil,
          attempt: non_neg_integer(),
          node: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          data: %{optional(String.t()) => term()} | nil,
          task_id: UUIDv7.t() | nil,
          task: Akvy.Tasks.Task.t() | Ecto.Association.NotLoaded.t() | nil
        }

  schema "task_events" do
    field :seq, :integer
    field :type, Ecto.Enum, values: @types
    field :attempt, :integer, default: 0
    field :node, :string
    field :occurred_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :data, :map, default: %{}

    belongs_to :task, Akvy.Tasks.Task
  end

  @doc "All event types."
  @spec types() :: [type()]
  def types, do: Keyword.keys(@types)
end
