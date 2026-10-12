defmodule AkvyWeb.Api.FallbackController do
  @moduledoc "Translates error results of API actions into JSON error responses."
  use AkvyWeb, :controller

  @typedoc "Non-`Plug.Conn` results of API actions handled by `call/2`."
  @type error ::
          nil
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :stale}
          | {:error, {:invalid_transition, Akvy.Tasks.Task.status(), atom()}}
          | {:error, atom(), String.t()}
          | {:error, term()}

  @doc "Renders `error` as `%{errors: %{detail: ...}}` with the matching HTTP status."
  @spec call(Plug.Conn.t(), error()) :: Plug.Conn.t()
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
    error(conn, :unprocessable_entity, "Validation failed", errors)
  end

  def call(conn, {:error, :not_found}), do: error(conn, :not_found, "Not found")
  def call(conn, nil), do: error(conn, :not_found, "Not found")

  def call(conn, {:error, {:invalid_transition, status, _type}}),
    do: error(conn, :conflict, "Not allowed while task is #{status}")

  def call(conn, {:error, :stale}),
    do: error(conn, :conflict, "Task was modified concurrently, retry")

  def call(conn, {:error, status, detail}) when is_atom(status), do: error(conn, status, detail)

  def call(conn, {:error, reason}),
    do: error(conn, :internal_server_error, "Internal error: #{inspect(reason)}")

  @spec error(Plug.Conn.t(), atom(), String.t(), map()) :: Plug.Conn.t()
  defp error(conn, status, detail, extra \\ %{}) do
    conn
    |> put_status(status)
    |> json(%{errors: Map.put(extra, :detail, detail)})
  end

  @spec translate_error({String.t(), keyword()}) :: String.t()
  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
