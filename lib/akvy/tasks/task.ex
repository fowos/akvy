defmodule Akvy.Tasks.Task do
  @moduledoc """
  Snapshot of the current state of a conversion task.

  The snapshot is a projection of `Akvy.Tasks.TaskEvent` rows (see
  `Akvy.Tasks.Projector`) and is only ever written together with a new event.
  """
  use Akvy.Schema

  @statuses ~w(uploaded processing retrying completed downloading failed downloaded expired cancelled)a
  @terminal ~w(failed downloaded expired cancelled)a
  @active ~w(uploaded processing retrying)a

  @type status ::
          :uploaded
          | :processing
          | :retrying
          | :completed
          | :downloading
          | :failed
          | :downloaded
          | :expired
          | :cancelled

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          status: status() | nil,
          version: non_neg_integer(),
          attempt: non_neg_integer(),
          node: String.t() | nil,
          original_filename: String.t() | nil,
          content_type: String.t() | nil,
          input_key: String.t() | nil,
          input_size: non_neg_integer() | nil,
          output_key: String.t() | nil,
          output_size: non_neg_integer() | nil,
          error: String.t() | nil,
          exit_code: integer() | nil,
          uploaded_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          downloaded_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          input_deleted_at: DateTime.t() | nil,
          output_deleted_at: DateTime.t() | nil,
          upload_ms: non_neg_integer() | nil,
          queue_wait_ms: non_neg_integer() | nil,
          s3_download_ms: non_neg_integer() | nil,
          ffmpeg_ms: non_neg_integer() | nil,
          s3_upload_ms: non_neg_integer() | nil,
          processing_ms: integer() | nil,
          total_ms: integer() | nil,
          queue_id: UUIDv7.t() | nil,
          queue: Akvy.Queues.Queue.t() | Ecto.Association.NotLoaded.t() | nil,
          api_key_id: UUIDv7.t() | nil,
          api_key: Akvy.ApiKeys.ApiKey.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "tasks" do
    field :status, Ecto.Enum, values: @statuses
    field :version, :integer, default: 0
    field :attempt, :integer, default: 0
    field :node, :string
    field :original_filename, :string
    field :content_type, :string
    field :input_key, :string
    field :input_size, :integer
    field :output_key, :string
    field :output_size, :integer
    field :error, :string
    field :exit_code, :integer

    field :uploaded_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :downloaded_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :input_deleted_at, :utc_datetime_usec
    field :output_deleted_at, :utc_datetime_usec

    field :upload_ms, :integer
    field :queue_wait_ms, :integer
    field :s3_download_ms, :integer
    field :ffmpeg_ms, :integer
    field :s3_upload_ms, :integer
    field :processing_ms, :integer
    field :total_ms, :integer

    belongs_to :queue, Akvy.Queues.Queue
    belongs_to :api_key, Akvy.ApiKeys.ApiKey

    timestamps()
  end

  @doc "All task statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Statuses after which nothing else will happen to the task."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal

  @doc "Statuses in which the task is waiting for or undergoing conversion."
  @spec active_statuses() :: [status()]
  def active_statuses, do: @active

  @doc "Returns true when the task is in a terminal status."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal
end
