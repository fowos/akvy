defmodule Akvy.Tasks.TaskEvent do
  @moduledoc """
  Append-only history entry of a task. `seq` is a per-task sequence number that
  equals the snapshot `version` after the event has been applied.
  """
  use Akvy.Schema

  @types ~w(uploaded enqueued attempt_started s3_download_started s3_download_finished
            ffmpeg_started ffmpeg_finished s3_upload_started s3_upload_finished attempt_failed
            retry_scheduled completed failed input_deleted download_started download_aborted
            downloaded output_deleted expired cancelled)a

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
  def types, do: @types
end
