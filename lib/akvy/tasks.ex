defmodule Akvy.Tasks do
  @moduledoc """
  Conversion tasks: creation, state transitions, history and logs.

  Every state change is written as an append-only `TaskEvent` together with an
  update of the `Task` snapshot in a single transaction. The snapshot update is
  guarded by an optimistic lock on `version`, so concurrent writers (several
  instances, API requests, cron) can never apply conflicting transitions.

  After commit, a compact notification is broadcast via `Phoenix.PubSub`, which
  delivers it to subscribers on every node of the Erlang cluster (see `Akvy.Cluster`),
  so SSE streams and LiveViews on any instance receive all task updates.
  """
  import Ecto.Query
  require Logger

  alias Akvy.{Instance, Repo, Storage}
  alias Akvy.ApiKeys.ApiKey
  alias Akvy.Queues.Queue
  alias Akvy.Tasks.{Projector, Task, TaskEvent, TaskLog}
  alias Akvy.Workers.Convert

  @pubsub Akvy.PubSub

  @typedoc "JSON-friendly task notification, see `notification_payload/2`."
  @type payload :: %{required(String.t()) => String.t() | integer() | nil}

  @type filter ::
          {:status, Task.status() | String.t() | nil}
          | {:queue_id, UUIDv7.t() | nil}
          | {:api_key_id, UUIDv7.t() | nil}
          | {:since, DateTime.t()}
          | {:before_id, UUIDv7.t() | nil}
          | {:limit, pos_integer()}

  @type filters :: %{optional(atom()) => term()} | [filter()]

  @type log_option :: {:limit, pos_integer()} | {:attempt, non_neg_integer() | nil}

  @typedoc "Uploaded file: local `:path` plus client-supplied metadata."
  @type upload :: %{
          required(:path) => Path.t(),
          optional(:filename) => String.t() | nil,
          optional(:content_type) => String.t() | nil
        }

  @type record_option ::
          {:attempt, non_neg_integer()}
          | {:duration_ms, non_neg_integer() | nil}
          | {:data, %{optional(String.t()) => term()}}
          | {:occurred_at, DateTime.t()}

  @type record_error :: :stale | Projector.invalid_transition()

  @type record_result :: {:ok, Task.t(), TaskEvent.t()} | {:error, record_error()}

  @typedoc "Log line for `insert_logs/2`; `:line`, `:level` and `:at` are optional."
  @type log_entry :: %{
          required(:attempt) => non_neg_integer(),
          required(:source) => TaskLog.source(),
          required(:message) => String.t(),
          optional(:line) => non_neg_integer(),
          optional(:level) => TaskLog.level(),
          optional(:at) => DateTime.t()
        }

  ## PubSub

  @doc "PubSub topic for a single task."
  @spec task_topic(UUIDv7.t()) :: String.t()
  def task_topic(task_id), do: "task:#{task_id}"

  @doc "PubSub topic for all tasks of an API key."
  @spec api_key_topic(UUIDv7.t()) :: String.t()
  def api_key_topic(api_key_id), do: "api_key:#{api_key_id}"

  @doc "PubSub topic for all tasks."
  @spec all_tasks_topic() :: String.t()
  def all_tasks_topic, do: "tasks"

  @doc "Subscribes the caller to updates of one task."
  @spec subscribe_task(UUIDv7.t()) :: :ok | {:error, term()}
  def subscribe_task(task_id), do: Phoenix.PubSub.subscribe(@pubsub, task_topic(task_id))

  @doc "Subscribes the caller to updates of all tasks of an API key."
  @spec subscribe_api_key(UUIDv7.t()) :: :ok | {:error, term()}
  def subscribe_api_key(api_key_id),
    do: Phoenix.PubSub.subscribe(@pubsub, api_key_topic(api_key_id))

  @doc "Subscribes the caller to updates of all tasks."
  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all, do: Phoenix.PubSub.subscribe(@pubsub, all_tasks_topic())

  @doc """
  Broadcasts a notification payload to subscribers on all cluster nodes.
  Subscribers receive `{:akvy_task, payload}`.
  """
  @spec broadcast_payload(payload()) :: :ok
  def broadcast_payload(%{"id" => id} = payload) do
    message = {:akvy_task, payload}
    Phoenix.PubSub.broadcast(@pubsub, task_topic(id), message)
    Phoenix.PubSub.broadcast(@pubsub, all_tasks_topic(), message)

    if api_key_id = payload["api_key_id"] do
      Phoenix.PubSub.broadcast(@pubsub, api_key_topic(api_key_id), message)
    end

    :ok
  end

  ## Queries

  @doc "Fetches a task by id, returning nil for unknown or malformed ids."
  @spec get_task(term()) :: Task.t() | nil
  def get_task(id) do
    case UUIDv7.cast(id) do
      {:ok, id} -> Repo.get(Task, id)
      :error -> nil
    end
  end

  @doc "Fetches a task by id. Raises `Ecto.NoResultsError` if not found."
  @spec get_task!(UUIDv7.t()) :: Task.t()
  def get_task!(id), do: Repo.get!(Task, id)

  @doc "Fetches a task only if it belongs to the given API key."
  @spec get_task_for_api_key(ApiKey.t(), term()) :: Task.t() | nil
  def get_task_for_api_key(%ApiKey{id: api_key_id}, id) do
    case get_task(id) do
      %Task{api_key_id: ^api_key_id} = task -> task
      _ -> nil
    end
  end

  @doc """
  Lists tasks newest first with keyset pagination.

  Filters: `:status`, `:queue_id`, `:api_key_id`, `:since` (DateTime), `:before_id`
  (cursor — id of the last task of the previous page), `:limit` (default 50).
  Empty values are ignored. The `:queue` association is preloaded.
  """
  @spec list_tasks(filters()) :: [Task.t()]
  def list_tasks(filters \\ %{}) do
    filters = Map.new(filters)
    limit = Map.get(filters, :limit, 50)

    Task
    |> filter_tasks(filters)
    |> order_by([t], desc: t.id)
    |> limit(^limit)
    |> preload(:queue)
    |> Repo.all()
  end

  defp filter_tasks(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, status}, q when status not in [nil, ""] -> where(q, [t], t.status == ^status)
      {:queue_id, id}, q when id not in [nil, ""] -> where(q, [t], t.queue_id == ^id)
      {:api_key_id, id}, q when id not in [nil, ""] -> where(q, [t], t.api_key_id == ^id)
      {:since, %DateTime{} = since}, q -> where(q, [t], t.inserted_at >= ^since)
      {:before_id, id}, q when id not in [nil, ""] -> where(q, [t], t.id < ^id)
      _, q -> q
    end)
  end

  @doc "Lists the events of a task ordered by `seq`."
  @spec list_events(UUIDv7.t()) :: [TaskEvent.t()]
  def list_events(task_id) do
    Repo.all(from e in TaskEvent, where: e.task_id == ^task_id, order_by: e.seq)
  end

  @doc """
  Lists log lines of a task ordered by attempt and line.

  Options: `:attempt` (only this attempt), `:limit` (default 2000).
  """
  @spec list_logs(UUIDv7.t(), [log_option()]) :: [TaskLog.t()]
  def list_logs(task_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 2000)

    TaskLog
    |> where([l], l.task_id == ^task_id)
    |> then(fn q ->
      case Keyword.get(opts, :attempt) do
        nil -> q
        attempt -> where(q, [l], l.attempt == ^attempt)
      end
    end)
    |> order_by([l], asc: l.attempt, asc: l.line, asc: l.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  ## Creation

  @doc """
  Stores the uploaded file in S3 and creates the task with its first events and
  the conversion job in a single transaction.

  `upload` is a map with `:path`, `:filename` and `:content_type`.
  """
  def create_task(%Queue{} = queue, api_key, %{path: path} = upload) do
    id = UUIDv7.generate()
    input_key = "inputs/#{id}"
    size = File.stat!(path).size

    {upload_ms, result} =
      timed(fn -> Storage.put_file(input_key, path, content_type: upload[:content_type]) end)

    with :ok <- result,
         {:ok, {task, events}} <-
           insert_task(id, queue, api_key, upload, input_key, size, upload_ms) do
      Enum.each(events, &broadcast(task, &1))
      {:ok, task}
    else
      {:error, reason} = error ->
        Logger.error("task creation failed: #{inspect(reason)}")
        _ = Storage.delete(input_key)
        error
    end
  end

  defp insert_task(id, queue, api_key, upload, input_key, size, upload_ms) do
    Repo.transaction(fn ->
      uploaded =
        build_event(%Task{id: id, version: 0}, :uploaded,
          duration_ms: upload_ms,
          data: %{
            "queue_id" => queue.id,
            "api_key_id" => api_key && api_key.id,
            "original_filename" => upload[:filename],
            "content_type" => upload[:content_type],
            "input_key" => input_key,
            "input_size" => size
          }
        )

      {:ok, changes} = Projector.project(%Task{id: id}, uploaded)
      task = Repo.insert!(struct(%Task{id: id}, changes))
      Repo.insert!(uploaded)

      job =
        Oban.insert!(
          Convert.new(%{"task_id" => id},
            max_attempts: queue.max_attempts,
            meta: %{"timeout_ms" => queue.timeout_seconds * 1000}
          )
        )

      case apply_event(task, :enqueued, data: %{"job_id" => job.id}) do
        {:ok, task, enqueued} -> {task, [uploaded, enqueued]}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  ## Transitions

  @doc """
  Records an event and updates the snapshot.

  Options: `:attempt`, `:duration_ms`, `:data` (string-keyed map), `:occurred_at`.
  Returns `{:ok, task, event}`, `{:error, :stale}` when another writer changed the
  task first, or `{:error, {:invalid_transition, status, type}}`.
  """
  def record(%Task{} = task, type, opts \\ []) do
    case Repo.transaction(fn ->
           case apply_event(task, type, opts) do
             {:ok, task, event} -> {task, event}
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {task, event}} ->
        broadcast(task, event)
        {:ok, task, event}

      {:error, _} = error ->
        error
    end
  end

  @doc "Like `record/3`, but reloads the task and retries once on a stale version."
  def record_fresh(%Task{} = task, type, opts \\ []) do
    case record(task, type, opts) do
      {:error, :stale} -> record(get_task!(task.id), type, opts)
      other -> other
    end
  end

  defp apply_event(%Task{} = task, type, opts) do
    event = build_event(task, type, opts)

    with {:ok, changes} <- Projector.project(task, event) do
      now = DateTime.utc_now()
      set = changes |> Map.put(:updated_at, now) |> Enum.to_list()

      query =
        from t in Task, where: t.id == ^task.id and t.version == ^task.version, select: t

      case Repo.update_all(query, set: set) do
        {1, [updated]} ->
          event = Repo.insert!(event)
          {:ok, updated, event}

        {0, _} ->
          {:error, :stale}
      end
    end
  end

  defp build_event(%Task{} = task, type, opts) do
    %TaskEvent{
      id: UUIDv7.generate(),
      task_id: task.id,
      seq: task.version + 1,
      type: type,
      attempt: Keyword.get(opts, :attempt, task.attempt || 0),
      node: Instance.id(),
      occurred_at: Keyword.get_lazy(opts, :occurred_at, &DateTime.utc_now/0),
      duration_ms: Keyword.get(opts, :duration_ms),
      data: Keyword.get(opts, :data, %{})
    }
  end

  defp broadcast(%Task{} = task, %TaskEvent{} = event) do
    task
    |> notification_payload(event)
    |> broadcast_payload()
  end

  @doc "Compact, JSON-friendly notification sent to subscribers and SSE clients."
  def notification_payload(%Task{} = task, %TaskEvent{} = event) do
    %{
      "id" => task.id,
      "queue_id" => task.queue_id,
      "api_key_id" => task.api_key_id,
      "status" => to_string(task.status),
      "event" => to_string(event.type),
      "seq" => event.seq,
      "attempt" => task.attempt,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "duration_ms" => event.duration_ms,
      "error" => task.error && String.slice(task.error, 0, 500),
      "output_size" => task.output_size,
      "expires_at" => task.expires_at && DateTime.to_iso8601(task.expires_at)
    }
  end

  ## Download lifecycle

  @doc "Locks a completed task for download (completed -> downloading)."
  def start_download(%Task{} = task), do: record(task, :download_started)

  @doc "Marks the result as downloaded and removes it from storage."
  def finish_download(%Task{} = task) do
    with {:ok, task, _} <- record_fresh(task, :downloaded) do
      delete_output(task)
    end
  end

  def abort_download(%Task{} = task) do
    with {:ok, task, _} <- record_fresh(task, :download_aborted), do: {:ok, task}
  end

  ## Cancellation & cleanup

  @doc """
  Cancels a task: stops its job (including a running ffmpeg on any instance) and
  removes its files. Allowed while the task is queued, processing or completed.
  """
  def cancel_task(%Task{} = task) do
    with {:ok, task, _} <- record_fresh(task, :cancelled) do
      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where: j.worker == ^inspect(Convert) and fragment("?->>'task_id'", j.args) == ^task.id
        )
      )

      with {:ok, task} <- delete_input(task), do: delete_output(task)
    end
  end

  @doc "Deletes the source file from storage (once) and records it."
  def delete_input(%Task{input_key: key, input_deleted_at: nil} = task) when is_binary(key) do
    with :ok <- Storage.delete(key),
         {:ok, task, _} <- record_fresh(task, :input_deleted, data: %{"key" => key}) do
      {:ok, task}
    end
  end

  def delete_input(%Task{} = task), do: {:ok, task}

  @doc "Deletes the converted file from storage (once) and records it."
  def delete_output(%Task{output_key: key, output_deleted_at: nil} = task) when is_binary(key) do
    with :ok <- Storage.delete(key),
         {:ok, task, _} <- record_fresh(task, :output_deleted, data: %{"key" => key}) do
      {:ok, task}
    end
  end

  def delete_output(%Task{} = task), do: {:ok, task}

  ## History

  @doc "Rebuilds the snapshot of a task from its event history and persists it."
  def rebuild_snapshot(task_id) do
    task = get_task!(task_id)
    events = list_events(task_id)

    with {:ok, rebuilt} <- Projector.replay(events, %Task{id: task.id}) do
      fields = Task.__schema__(:fields) -- [:id, :inserted_at, :updated_at]
      set = Enum.map(fields, &{&1, Map.get(rebuilt, &1)})
      {1, _} = Repo.update_all(from(t in Task, where: t.id == ^task.id), set: set)
      {:ok, get_task!(task_id)}
    end
  end

  ## Logs

  @doc "Inserts log rows. Each entry: `%{attempt, source, level, message}`."
  def insert_logs(_task_id, []), do: :ok

  def insert_logs(task_id, entries) do
    now = DateTime.utc_now()

    rows =
      Enum.map(entries, fn entry ->
        %{
          id: UUIDv7.generate(),
          task_id: task_id,
          attempt: entry.attempt,
          line: Map.get(entry, :line, 0),
          source: entry.source,
          level: Map.get(entry, :level, :info),
          message: String.slice(entry.message, 0, 4000),
          inserted_at: Map.get(entry, :at, now)
        }
      end)

    Repo.insert_all(TaskLog, rows)
    :ok
  end

  ## Helpers

  @doc false
  def timed(fun) do
    started = System.monotonic_time()
    result = fun.()
    {System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond), result}
  end
end
