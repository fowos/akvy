defmodule AkvyWeb.MultipartParser do
  @moduledoc """
  Multipart parser whose body size limit comes from the target queue.

  Wraps `Plug.Parsers.MULTIPART` (the approach recommended by Plug for dynamic
  configuration). For `POST /api/v1/queues/:queue_id/tasks` the limit is the
  queue's `max_file_size_bytes` plus room for multipart headers; requests
  declaring a larger `Content-Length` are rejected before reading the body.
  Every other multipart request gets a small default limit.
  """
  @behaviour Plug.Parsers

  alias Akvy.Queues

  @multipart Plug.Parsers.MULTIPART
  @default_length 1_000_000
  @envelope_overhead 64 * 1024

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(conn, "multipart", subtype, headers, opts) do
    length = max_length(conn)

    if declared_length(conn) > length do
      raise Plug.Parsers.RequestTooLargeError
    end

    opts = @multipart.init(Keyword.put(opts, :length, length))
    @multipart.parse(conn, "multipart", subtype, headers, opts)
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  @spec max_length(Plug.Conn.t()) :: pos_integer()
  defp max_length(%Plug.Conn{method: "POST", path_info: ["api", "v1", "queues", id, "tasks"]}) do
    case Queues.get_queue(id) do
      %{max_file_size_bytes: max} -> max + @envelope_overhead
      nil -> @default_length
    end
  end

  defp max_length(_conn), do: @default_length

  @spec declared_length(Plug.Conn.t()) :: integer()
  defp declared_length(conn) do
    with [value | _] <- Plug.Conn.get_req_header(conn, "content-length"),
         {length, ""} <- Integer.parse(value) do
      length
    else
      _ -> 0
    end
  end
end
