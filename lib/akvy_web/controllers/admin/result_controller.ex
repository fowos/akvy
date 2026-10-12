defmodule AkvyWeb.Admin.ResultController do
  @moduledoc """
  Admin download of a converted file (`/admin/tasks/:id/result`).

  Read-only: unlike the client API it records no events, so the task stays
  `completed` and the file is still deleted only after the client downloads it
  (or after the queue's TTL).
  """
  use AkvyWeb, :controller

  require Logger

  alias Akvy.{Queues, Storage, Tasks}
  alias AkvyWeb.ResultFile

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with task when not is_nil(task) <- Tasks.get_task(id),
         true <- Tasks.result_available?(task),
         {:ok, stream, size} <- Storage.stream(task.output_key) do
      Logger.info("admin #{conn.assigns.current_scope.user.email} downloads result of #{task.id}")

      case ResultFile.send(conn, task, Queues.get_queue!(task.queue_id), stream, size) do
        {:ok, conn} -> conn
        {:error, conn, _reason} -> conn
      end
    else
      nil ->
        conn |> put_flash(:error, "Task not found") |> redirect(to: ~p"/admin/tasks")

      _ ->
        conn
        |> put_flash(:error, "Result is no longer available")
        |> redirect(to: ~p"/admin/tasks/#{id}")
    end
  end
end
