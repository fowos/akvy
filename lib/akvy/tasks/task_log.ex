defmodule Akvy.Tasks.TaskLog do
  @moduledoc """
  Verbose log line of a task attempt (ffmpeg output or worker message).
  Logs are pruned according to the queue's `log_retention_days`.
  """
  use Akvy.Schema

  @type source :: :ffmpeg | :worker
  @type level :: :debug | :info | :warning | :error

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          attempt: non_neg_integer(),
          line: non_neg_integer(),
          source: source() | nil,
          level: level(),
          message: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          task_id: UUIDv7.t() | nil,
          task: Akvy.Tasks.Task.t() | Ecto.Association.NotLoaded.t() | nil
        }

  schema "task_logs" do
    field :attempt, :integer, default: 0
    field :line, :integer, default: 0
    # Stored as smallint; codes must never change.
    field :source, Ecto.Enum, values: [ffmpeg: 1, worker: 2]
    field :level, Ecto.Enum, values: [debug: 1, info: 2, warning: 3, error: 4], default: :info
    field :message, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :task, Akvy.Tasks.Task
  end
end
