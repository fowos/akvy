defmodule AkvyWeb.Api.TaskController do
  @moduledoc "Client API: upload, list, inspect, download and cancel conversion tasks."
  use AkvyWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Akvy.{Queues, Storage, Tasks}
  alias Akvy.Queues.Queue
  alias Akvy.Tasks.Task
  alias AkvyWeb.Api.Schemas
  alias AkvyWeb.ResultFile
  alias OpenApiSpex.Schema

  action_fallback AkvyWeb.Api.FallbackController

  tags ["Tasks"]

  @security [%{"bearer" => []}]
  @unauthorized {"Missing or invalid API key", "application/json", Schemas.Error}

  @type action_result :: Plug.Conn.t() | AkvyWeb.Api.FallbackController.error()

  @typep action_error :: {:error, atom(), String.t()}

  @task_id [id: [in: :path, type: :string, description: "Task id", required: true]]

  operation :create,
    summary: "Upload a file for conversion",
    description:
      "Streams the file to storage and enqueues the conversion. The maximum size and accepted " <>
        "content types are configured per queue.",
    parameters: [queue_id: [in: :path, type: :string, description: "Queue id", required: true]],
    request_body:
      {"File", "multipart/form-data",
       %Schema{
         type: :object,
         properties: %{file: %Schema{type: :string, format: :binary}},
         required: [:file]
       }, required: true},
    security: @security,
    responses: [
      unauthorized: @unauthorized,
      accepted: {"Task created", "application/json", Schemas.TaskResponse},
      not_found: {"Queue not found or disabled", "application/json", Schemas.Error},
      request_entity_too_large:
        {"File exceeds the queue limit", "application/json", Schemas.Error},
      unsupported_media_type:
        {"Content type not accepted by the queue", "application/json", Schemas.Error},
      unprocessable_entity: {"Missing file", "application/json", Schemas.Error},
      service_unavailable: {"Storage is unavailable", "application/json", Schemas.Error}
    ]

  @spec create(Plug.Conn.t(), map()) :: action_result()
  def create(conn, %{"queue_id" => queue_id} = params) do
    with %Queue{enabled: true} = queue <- Queues.get_queue(queue_id) || {:error, :not_found},
         {:ok, upload} <- fetch_upload(params),
         :ok <- check_content_type(queue, upload),
         {:ok, task} <-
           Tasks.create_task(queue, conn.assigns.api_key, %{
             path: upload.path,
             filename: upload.filename,
             content_type: upload.content_type
           }) do
      conn
      |> put_status(:accepted)
      |> put_resp_header("location", ~p"/api/v1/tasks/#{task.id}")
      |> render(:show, task: task)
    else
      %Queue{enabled: false} -> {:error, :not_found}
      {:error, status, _detail} = error when is_atom(status) -> error
      {:error, :not_found} = error -> error
      {:error, _reason} -> {:error, :service_unavailable, "Storage is unavailable, retry later"}
    end
  end

  operation :index,
    summary: "List tasks",
    description: "Tasks created with the current API key, newest first.",
    parameters: [
      status: [in: :query, type: :string, description: "Filter by status"],
      queue_id: [in: :query, type: :string, description: "Filter by queue"],
      cursor: [in: :query, type: :string, description: "`next_cursor` from the previous page"],
      limit: [in: :query, type: :integer, description: "Page size (1-200, default 50)"]
    ],
    security: @security,
    responses: [
      unauthorized: @unauthorized,
      ok: {"Tasks", "application/json", Schemas.TaskList}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    limit = params |> Map.get("limit", "50") |> parse_int(50) |> min(200) |> max(1)

    filters = %{
      api_key_id: conn.assigns.api_key.id,
      status: parse_status(params["status"]),
      queue_id: valid_uuid(params["queue_id"]),
      before_id: valid_uuid(params["cursor"]),
      limit: limit
    }

    tasks = Tasks.list_tasks(filters)
    cursor = if length(tasks) == limit, do: List.last(tasks).id

    render(conn, :index, tasks: tasks, next_cursor: cursor)
  end

  operation :show,
    summary: "Get a task",
    parameters: @task_id,
    security: @security,
    responses: [
      unauthorized: @unauthorized,
      ok: {"Task", "application/json", Schemas.TaskResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]

  @spec show(Plug.Conn.t(), map()) :: action_result()
  def show(conn, %{"id" => id}) do
    with %Task{} = task <- fetch_task(conn, id) do
      render(conn, :show, task: task)
    end
  end

  operation :result,
    summary: "Download the result",
    description:
      "Streams the converted file. After a complete download the file is deleted from storage " <>
        "and the task becomes `downloaded`; an interrupted download can be retried.",
    parameters: @task_id,
    security: @security,
    responses: [
      unauthorized: @unauthorized,
      ok: {"Converted file", "application/octet-stream", %Schema{type: :string, format: :binary}},
      conflict: {"Not completed yet or being downloaded", "application/json", Schemas.Error},
      gone: {"Already downloaded or expired", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]

  @spec result(Plug.Conn.t(), map()) :: action_result()
  def result(conn, %{"id" => id}) do
    with %Task{} = task <- fetch_task(conn, id),
         :ok <- downloadable(task),
         {:ok, task, _} <- Tasks.start_download(task) do
      case Storage.stream(task.output_key) do
        {:ok, stream, size} ->
          send_result(conn, task, stream, size)

        {:error, reason} ->
          Logger.error("result #{task.id} unavailable: #{inspect(reason)}")
          Tasks.abort_download(task)
          {:error, :internal_server_error, "Result is unavailable"}
      end
    end
  end

  operation :delete,
    summary: "Cancel a task",
    description:
      "Stops the conversion (if running) and deletes the source and result files. " <>
        "Allowed for queued, processing and completed tasks.",
    parameters: @task_id,
    security: @security,
    responses: [
      unauthorized: @unauthorized,
      ok: {"Cancelled task", "application/json", Schemas.TaskResponse},
      conflict: {"Task cannot be cancelled", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]

  @spec delete(Plug.Conn.t(), map()) :: action_result()
  def delete(conn, %{"id" => id}) do
    with %Task{} = task <- fetch_task(conn, id),
         {:ok, task} <- Tasks.cancel_task(task) do
      render(conn, :show, task: task)
    end
  end

  @spec send_result(Plug.Conn.t(), Task.t(), Enumerable.t(), non_neg_integer()) :: Plug.Conn.t()
  defp send_result(conn, task, stream, size) do
    queue = Queues.get_queue!(task.queue_id)

    case ResultFile.send(conn, task, queue, stream, size) do
      {:ok, conn} ->
        Tasks.finish_download(task)
        conn

      {:error, conn, reason} ->
        Logger.info("download of #{task.id} interrupted: #{inspect(reason)}")
        Tasks.abort_download(task)
        conn
    end
  end

  @spec downloadable(Task.t()) :: :ok | action_error()
  defp downloadable(%Task{status: :completed}), do: :ok

  defp downloadable(%Task{status: :downloading}),
    do: {:error, :conflict, "Result is being downloaded"}

  defp downloadable(%Task{status: status}) when status in [:downloaded, :expired, :cancelled],
    do: {:error, :gone, "Result is no longer available"}

  defp downloadable(%Task{status: :failed}), do: {:error, :gone, "Conversion failed"}
  defp downloadable(%Task{}), do: {:error, :conflict, "Conversion is not finished yet"}

  @spec fetch_task(Plug.Conn.t(), String.t()) :: Task.t() | nil
  defp fetch_task(conn, id), do: Tasks.get_task_for_api_key(conn.assigns.api_key, id)

  @spec fetch_upload(map()) :: {:ok, Plug.Upload.t()} | action_error()
  defp fetch_upload(%{"file" => %Plug.Upload{} = upload}), do: {:ok, upload}

  defp fetch_upload(_params),
    do: {:error, :unprocessable_entity, "Multipart field `file` is required"}

  @spec check_content_type(Queue.t(), Plug.Upload.t()) :: :ok | action_error()
  defp check_content_type(queue, upload) do
    if Queue.content_type_allowed?(queue, upload.content_type) do
      :ok
    else
      {:error, :unsupported_media_type,
       "Content type #{upload.content_type} is not accepted by this queue"}
    end
  end

  @spec parse_int(String.Chars.t(), integer()) :: integer()
  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  @spec parse_status(String.t() | nil) :: Task.status() | nil
  defp parse_status(nil), do: nil

  defp parse_status(status) do
    Enum.find(Task.statuses(), &(to_string(&1) == status))
  end

  @spec valid_uuid(String.t() | nil) :: UUIDv7.t() | nil
  defp valid_uuid(nil), do: nil

  defp valid_uuid(value) do
    case UUIDv7.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
