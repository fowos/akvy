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

  @typedoc """
  JSON-friendly task notification, see `notification_payload/2`.

  `status` and `event` are the string forms of `t:Akvy.Tasks.Task.status/0` and
  `t:Akvy.Tasks.TaskEvent.type/0`; timestamps are ISO 8601 strings.
  """
  @type payload :: %{
          id: UUIDv7.t(),
          queue_id: UUIDv7.t(),
          api_key_id: UUIDv7.t() | nil,
          status: String.t(),
          event: String.t(),
          seq: pos_integer(),
          attempt: non_neg_integer(),
          occurred_at: String.t(),
          duration_ms: non_neg_integer() | nil,
          error: String.t() | nil,
          output_size: non_neg_integer() | nil,
          expires_at: String.t() | nil
        }

  @type filter ::
          {:status, Task.status() | String.t() | nil}
          | {:queue_id, UUIDv7.t() | nil}
          | {:api_key_id, UUIDv7.t() | nil}
          | {:since, DateTime.t()}
          | {:before_id, UUIDv7.t() | nil}
          | {:limit, pos_integer()}

  @type filters :: [filter()] | %{optional(atom()) => term()}

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

  @typedoc "Event for `record_all/2`: a type, or a type with `t:record_option/0`s."
  @type event_spec :: TaskEvent.type() | {TaskEvent.type(), [record_option()]}

  @type record_all_result :: {:ok, Task.t(), [TaskEvent.t()]} | {:error, record_error()}

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
  def broadcast_payload(%{id: id} = payload) do
    message = {:akvy_task, payload}
    Phoenix.PubSub.broadcast(@pubsub, task_topic(id), message)
    Phoenix.PubSub.broadcast(@pubsub, all_tasks_topic(), message)

    if api_key_id = payload.api_key_id do
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

  @doc "Fetches a task with its queue in one query; nil for unknown or malformed ids."
  @spec get_task_with_queue(term()) :: Task.t() | nil
  def get_task_with_queue(id) do
    case UUIDv7.cast(id) do
      {:ok, id} ->
        Repo.one(
          from t in Task, join: q in assoc(t, :queue), where: t.id == ^id, preload: [queue: q]
        )

      :error ->
        nil
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

  @spec filter_tasks(Ecto.Queryable.t(), map()) :: Ecto.Query.t()
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

  `upload` is a map with `:path`, `:filename` and `:content_type`. On failure the
  stored input is deleted and the storage error or rollback reason is returned.
  """
  @spec create_task(Queue.t(), ApiKey.t() | nil, upload()) :: {:ok, Task.t()} | {:error, term()}
  def create_task(%Queue{} = queue, api_key, %{path: path} = upload) do
    id = UUIDv7.generate()
    input_key = "inputs/#{id}"
    size = File.stat!(path).size

    {upload_ms, result} =
      timed(fn -> Storage.put_file(input_key, path, content_type: upload[:content_type]) end)

    with :ok <- result,
         {:ok, {task, events}} <-
           insert_task(id, queue, api_key, upload, input_key, size, upload_ms) do
      broadcast_all(%Task{id: id}, events)
      {:ok, task}
    else
      {:error, reason} = error ->
        Logger.error("task creation failed: #{inspect(reason)}")
        _ = Storage.delete(input_key)
        error
    end
  end

  @spec insert_task(
          UUIDv7.t(),
          Queue.t(),
          ApiKey.t() | nil,
          upload(),
          Storage.key(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, {Task.t(), [TaskEvent.t()]}} | {:error, term()}
  defp insert_task(id, queue, api_key, upload, input_key, size, upload_ms) do
    Repo.transaction(fn ->
      job =
        Oban.insert!(
          Convert.new(%{"task_id" => id},
            max_attempts: queue.max_attempts,
            meta: %{"timeout_ms" => queue.timeout_seconds * 1000}
          )
        )

      uploaded =
        {:uploaded,
         duration_ms: upload_ms,
         data: %{
           "queue_id" => queue.id,
           "api_key_id" => api_key && api_key.id,
           "original_filename" => upload[:filename],
           "content_type" => upload[:content_type],
           "input_key" => input_key,
           "input_size" => size
         }}

      {:ok, task, events} =
        project(%Task{id: id}, [uploaded, {:enqueued, data: %{"job_id" => job.id}}])

      task = Repo.insert!(task)
      Repo.insert_all(TaskEvent, Enum.map(events, &event_row/1))
      {task, events}
    end)
  end

  ## Transitions

  @doc """
  Records an event and updates the snapshot.

  Options: `:attempt`, `:duration_ms`, `:data` (string-keyed map), `:occurred_at`.
  Returns `{:ok, task, event}`, `{:error, :stale}` when another writer changed the
  task first, or `{:error, {:invalid_transition, status, type}}`.
  """
  @spec record(Task.t(), TaskEvent.type(), [record_option()]) :: record_result()
  def record(%Task{} = task, type, opts \\ []) do
    with {:ok, task, [event]} <- record_all(task, [{type, opts}]), do: {:ok, task, event}
  end

  @doc "Like `record/3`, but reloads the task and retries once on a stale version."
  @spec record_fresh(Task.t(), TaskEvent.type(), [record_option()]) :: record_result()
  def record_fresh(%Task{} = task, type, opts \\ []) do
    with {:ok, task, [event]} <- record_all_fresh(task, [{type, opts}]), do: {:ok, task, event}
  end

  @doc """
  Records consecutive events in one transaction, e.g. the end of one stage and the
  start of the next. Each event is broadcast; either all of them are written or none.
  """
  @spec record_all(Task.t(), [event_spec()]) :: record_all_result()
  def record_all(%Task{} = task, specs) do
    with {:ok, updated, events} <- project(task, specs),
         {:ok, updated} <- Repo.transaction(fn -> write(task, updated, events) end) do
      broadcast_all(task, events)
      {:ok, updated, events}
    end
  end

  @doc "Like `record_all/2`, but reloads the task and retries once on a stale version."
  @spec record_all_fresh(Task.t(), [event_spec()]) :: record_all_result()
  def record_all_fresh(%Task{} = task, specs) do
    case record_all(task, specs) do
      {:error, :stale} -> record_all(get_task!(task.id), specs)
      other -> other
    end
  end

  # Applies the events in memory; returns the resulting snapshot and the events.
  @spec project(Task.t(), [event_spec()]) ::
          {:ok, Task.t(), [TaskEvent.t()]} | {:error, Projector.invalid_transition()}
  defp project(%Task{} = task, specs) do
    Enum.reduce_while(specs, {:ok, task, []}, fn spec, {:ok, task, events} ->
      {type, opts} = if is_atom(spec), do: {spec, []}, else: spec

      event = build_event(task, type, opts)

      case Projector.apply_event(task, event) do
        {:ok, task} -> {:cont, {:ok, task, events ++ [event]}}
        error -> {:halt, error}
      end
    end)
  end

  # Updates the changed snapshot fields, guarded by the version the events were built on.
  @spec write(Task.t(), Task.t(), [TaskEvent.t()]) :: Task.t()
  defp write(%Task{} = task, %Task{} = updated, events) do
    now = DateTime.utc_now()

    changes =
      for field <- Task.__schema__(:fields),
          Map.get(task, field) != Map.get(updated, field),
          do: {field, Map.get(updated, field)}

    query = from t in Task, where: t.id == ^task.id and t.version == ^task.version

    case Repo.update_all(query, set: [{:updated_at, now} | changes]) do
      {1, _} ->
        Repo.insert_all(TaskEvent, Enum.map(events, &event_row/1))
        %{updated | updated_at: now}

      {0, _} ->
        Repo.rollback(:stale)
    end
  end

  @spec event_row(TaskEvent.t()) :: map()
  defp event_row(%TaskEvent{} = event),
    do: Map.take(event, TaskEvent.__schema__(:fields))

  @spec build_event(Task.t(), TaskEvent.type(), [record_option()]) :: TaskEvent.t()
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

  # Broadcasts every event with the snapshot as it was right after that event.
  @spec broadcast_all(Task.t(), [TaskEvent.t()]) :: :ok
  defp broadcast_all(%Task{} = task, events) do
    Enum.reduce(events, task, fn event, task ->
      {:ok, task} = Projector.apply_event(task, event)
      task |> notification_payload(event) |> broadcast_payload()
      task
    end)

    :ok
  end

  @doc "Compact, JSON-friendly notification sent to subscribers and SSE clients."
  @spec notification_payload(Task.t(), TaskEvent.t()) :: payload()
  def notification_payload(%Task{} = task, %TaskEvent{} = event) do
    %{
      id: task.id,
      queue_id: task.queue_id,
      api_key_id: task.api_key_id,
      status: to_string(task.status),
      event: to_string(event.type),
      seq: event.seq,
      attempt: task.attempt,
      occurred_at: DateTime.to_iso8601(event.occurred_at),
      duration_ms: event.duration_ms,
      error: task.error && String.slice(task.error, 0, 500),
      output_size: task.output_size,
      expires_at: task.expires_at && DateTime.to_iso8601(task.expires_at)
    }
  end

  ## Download lifecycle

  @doc """
  True while the converted file is still in storage (completed or being downloaded by
  the client). The admin panel may read it then without affecting the lifecycle.
  """
  @spec result_available?(Task.t()) :: boolean()
  def result_available?(%Task{status: status, output_key: key, output_deleted_at: nil})
      when status in [:completed, :downloading] and is_binary(key),
      do: true

  def result_available?(%Task{}), do: false

  @doc "Locks a completed task for download (completed -> downloading)."
  @spec start_download(Task.t()) :: record_result()
  def start_download(%Task{} = task), do: record(task, :download_started)

  @doc "Marks the result as downloaded and removes it from storage."
  @spec finish_download(Task.t()) :: {:ok, Task.t()} | {:error, term()}
  def finish_download(%Task{} = task) do
    with {:ok, task, _} <- record_fresh(task, :downloaded) do
      delete_output(task)
    end
  end

  @doc "Releases the download lock (downloading -> completed)."
  @spec abort_download(Task.t()) :: {:ok, Task.t()} | {:error, record_error()}
  def abort_download(%Task{} = task) do
    with {:ok, task, _} <- record_fresh(task, :download_aborted), do: {:ok, task}
  end

  ## Cancellation & cleanup

  @doc """
  Cancels a task: stops its job (including a running ffmpeg on any instance) and
  removes its files. Allowed while the task is queued, processing or completed.
  """
  @spec cancel_task(Task.t()) :: {:ok, Task.t()} | {:error, term()}
  def cancel_task(%Task{} = task) do
    with {:ok, task, _} <- record_fresh(task, :cancelled) do
      Oban.cancel_all_jobs(from(j in Oban.Job, where: j.id == ^task.job_id))

      with {:ok, task} <- delete_input(task), do: delete_output(task)
    end
  end

  @doc "Deletes the source file from storage (once) and records it."
  @spec delete_input(Task.t()) :: {:ok, Task.t()} | {:error, term()}
  def delete_input(%Task{input_key: key, input_deleted_at: nil} = task) when is_binary(key) do
    with :ok <- Storage.delete(key),
         {:ok, task, _} <- record_fresh(task, :input_deleted, data: %{"key" => key}) do
      {:ok, task}
    end
  end

  def delete_input(%Task{} = task), do: {:ok, task}

  @doc "Deletes the converted file from storage (once) and records it."
  @spec delete_output(Task.t()) :: {:ok, Task.t()} | {:error, term()}
  def delete_output(%Task{output_key: key, output_deleted_at: nil} = task) when is_binary(key) do
    with :ok <- Storage.delete(key),
         {:ok, task, _} <- record_fresh(task, :output_deleted, data: %{"key" => key}) do
      {:ok, task}
    end
  end

  def delete_output(%Task{} = task), do: {:ok, task}

  ## History

  @doc "Rebuilds the snapshot of a task from its event history and persists it."
  @spec rebuild_snapshot(UUIDv7.t()) :: {:ok, Task.t()} | {:error, Projector.invalid_transition()}
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

  @doc "Inserts log rows in one statement; messages are truncated to 4000 characters."
  @spec insert_logs(UUIDv7.t(), [log_entry()]) :: :ok
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
  @spec timed((-> result)) :: {non_neg_integer(), result} when result: var
  def timed(fun) do
    started = System.monotonic_time()
    result = fun.()
    {System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond), result}
  end
end
