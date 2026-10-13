defmodule AkvyWeb.Api.EventController do
  @moduledoc """
  Server-Sent Events. Works on any instance: updates produced on other nodes
  arrive through the cluster-wide `Phoenix.PubSub`.
  """
  use AkvyWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Akvy.Tasks
  alias Akvy.Tasks.Task
  alias AkvyWeb.Api.{Schemas, TaskJSON}

  action_fallback AkvyWeb.Api.FallbackController

  tags ["Events"]

  # EventSource cannot send headers, so SSE also accepts `?api_key=`.
  @security [%{"bearer" => []}, %{"api_key" => []}]
  @unauthorized {"Missing or invalid API key", "application/json", Schemas.Error}

  @heartbeat_ms 15_000
  @closing_statuses ~w(completed failed cancelled expired downloaded)

  operation :task,
    summary: "Stream events of a task (SSE)",
    description:
      "`text/event-stream`. The first message is the current snapshot, followed by every " <>
        "task event (`event: task`, `id: <seq>`, `data: <TaskEvent JSON>`). A `: ping` comment is " <>
        "sent every 15s. The stream closes once the task is completed, failed, cancelled, " <>
        "expired or downloaded.",
    parameters: [
      id: [in: :path, type: :string, description: "Task id", required: true]
    ],
    security: @security,
    responses: [
      unauthorized: @unauthorized,
      ok: {"Event stream", "text/event-stream", Schemas.TaskEvent},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]

  @spec task(Plug.Conn.t(), map()) :: Plug.Conn.t() | AkvyWeb.Api.FallbackController.error()
  def task(conn, %{"id" => id}) do
    with %Task{} = task <- Tasks.get_task_for_api_key(conn.assigns.api_key, id) do
      # Subscribe before reading the snapshot so no event can be missed.
      Tasks.subscribe_task(task.id)
      Akvy.Shutdown.subscribe()
      task = Tasks.get_task!(task.id)
      conn = start_stream(conn)

      case send_event(conn, TaskJSON.snapshot_event(task)) do
        {:ok, conn} ->
          if to_string(task.status) in @closing_statuses,
            do: conn,
            else: loop(conn, task.version, &(&1.status in @closing_statuses))

        {:error, conn} ->
          conn
      end
    end
  end

  operation :index,
    summary: "Stream events of all tasks of the API key (SSE)",
    description: "Never closes on its own. Optionally filtered by queue.",
    parameters: [
      queue_id: [in: :query, type: :string, description: "Only events of this queue"]
    ],
    security: @security,
    responses: [
      unauthorized: @unauthorized,
      ok: {"Event stream", "text/event-stream", Schemas.TaskEvent}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    Tasks.subscribe_api_key(conn.assigns.api_key.id)
    Akvy.Shutdown.subscribe()
    queue_id = params["queue_id"]

    conn
    |> start_stream()
    |> loop(0, fn _ -> false end, fn payload ->
      is_nil(queue_id) or payload.queue_id == queue_id
    end)
  end

  @spec start_stream(Plug.Conn.t()) :: Plug.Conn.t()
  defp start_stream(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  # `min_seq` drops events already reflected in the snapshot (per-task streams).
  @spec loop(
          Plug.Conn.t(),
          non_neg_integer(),
          (Tasks.payload() -> boolean()),
          (Tasks.payload() -> boolean())
        ) :: Plug.Conn.t()
  defp loop(conn, min_seq, done?, include? \\ fn _ -> true end) do
    receive do
      {:akvy_task, payload} ->
        cond do
          not include?.(payload) ->
            loop(conn, min_seq, done?, include?)

          min_seq > 0 and payload.seq <= min_seq ->
            loop(conn, min_seq, done?, include?)

          true ->
            case send_event(conn, Map.delete(payload, :api_key_id)) do
              {:ok, conn} ->
                if done?.(payload), do: conn, else: loop(conn, min_seq, done?, include?)

              {:error, conn} ->
                conn
            end
        end

      # The instance is stopping: end the stream, EventSource reconnects to another one.
      :akvy_shutdown ->
        conn
    after
      @heartbeat_ms ->
        case chunk(conn, ": ping\n\n") do
          {:ok, conn} -> loop(conn, min_seq, done?, include?)
          {:error, _} -> conn
        end
    end
  end

  @spec send_event(Plug.Conn.t(), TaskJSON.event_json()) :: {:ok | :error, Plug.Conn.t()}
  defp send_event(conn, event) do
    message = "event: task\nid: #{event.seq}\ndata: #{Jason.encode!(event)}\n\n"

    case chunk(conn, message) do
      {:ok, conn} -> {:ok, conn}
      {:error, _} -> {:error, conn}
    end
  end
end
