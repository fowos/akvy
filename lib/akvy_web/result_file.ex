defmodule AkvyWeb.ResultFile do
  @moduledoc """
  Streams a converted file from storage to the client. Shared by the client API
  (which records the download) and the admin panel (which does not).
  """
  import Plug.Conn

  alias Akvy.Queues.Queue
  alias Akvy.Tasks.Task

  @doc """
  Sends `stream` as a chunked attachment named after the task's original file.
  Returns `{:error, conn, reason}` when the transfer is interrupted.
  """
  @spec send(Plug.Conn.t(), Task.t(), Queue.t(), Enumerable.t(), non_neg_integer()) ::
          {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t(), term()}
  def send(conn, task, queue, stream, size) do
    conn =
      conn
      |> put_resp_content_type(queue.output_content_type, nil)
      |> put_resp_header("content-disposition", content_disposition(task, queue))
      |> put_resp_header("x-file-size", to_string(size))
      |> send_chunked(200)

    try do
      Enum.reduce_while(stream, {:ok, conn}, fn chunk, {:ok, conn} ->
        case chunk(conn, chunk) do
          {:ok, conn} -> {:cont, {:ok, conn}}
          {:error, reason} -> {:halt, {:error, conn, reason}}
        end
      end)
    rescue
      error -> {:error, conn, Exception.message(error)}
    end
  end

  @doc "`attachment` header with an ASCII fallback and an RFC 5987 UTF-8 filename."
  @spec content_disposition(Task.t(), Queue.t()) :: String.t()
  def content_disposition(task, queue) do
    base =
      (task.original_filename || task.id)
      |> Path.rootname()
      |> String.replace(~r/[\x00-\x1f"\\\/]/u, "_")

    filename = "#{base}.#{queue.output_extension}"
    ascii = String.replace(filename, ~r/[^\x20-\x7e]/u, "_")

    ~s(attachment; filename="#{ascii}"; filename*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)})
  end
end
