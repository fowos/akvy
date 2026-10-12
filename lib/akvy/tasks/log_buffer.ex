defmodule Akvy.Tasks.LogBuffer do
  @moduledoc """
  In-process buffer for task log lines. Lines are written with `insert_all` in
  batches (every `@max_lines` lines or `@max_age_ms`) to avoid a transaction
  per ffmpeg output line.
  """
  alias Akvy.Tasks
  alias Akvy.Tasks.TaskLog

  @max_lines 200
  @max_age_ms 1_000

  defstruct [:task_id, :attempt, entries: [], count: 0, line: 0, flushed_at: nil]

  @typedoc "Buffered line; `:at` is the wall-clock time it was added."
  @type entry :: %{
          attempt: non_neg_integer(),
          line: pos_integer(),
          source: TaskLog.source(),
          level: TaskLog.level(),
          message: String.t(),
          at: DateTime.t()
        }

  @typedoc "`flushed_at` is a monotonic timestamp in milliseconds."
  @type t :: %__MODULE__{
          task_id: UUIDv7.t(),
          attempt: non_neg_integer(),
          entries: [entry()],
          count: non_neg_integer(),
          line: non_neg_integer(),
          flushed_at: integer() | nil
        }

  @doc "Creates an empty buffer for one task attempt."
  @spec new(UUIDv7.t(), non_neg_integer()) :: t()
  def new(task_id, attempt) do
    %__MODULE__{task_id: task_id, attempt: attempt, flushed_at: now()}
  end

  @doc "Appends a line, flushing to the database when the size or age limit is reached."
  @spec add(t(), TaskLog.source(), TaskLog.level(), String.t()) :: t()
  def add(%__MODULE__{} = buf, source, level, message) do
    line = buf.line + 1

    entry = %{
      attempt: buf.attempt,
      line: line,
      source: source,
      level: level,
      message: message,
      at: DateTime.utc_now()
    }

    buf = %{buf | entries: [entry | buf.entries], count: buf.count + 1, line: line}

    if buf.count >= @max_lines or now() - buf.flushed_at >= @max_age_ms do
      flush(buf)
    else
      buf
    end
  end

  @doc "Writes all buffered lines to the database and resets the buffer."
  @spec flush(t()) :: t()
  def flush(%__MODULE__{entries: []} = buf), do: %{buf | flushed_at: now()}

  def flush(%__MODULE__{} = buf) do
    :ok = Tasks.insert_logs(buf.task_id, Enum.reverse(buf.entries))
    %{buf | entries: [], count: 0, flushed_at: now()}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
