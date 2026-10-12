defmodule AkvyWeb.HealthController do
  @moduledoc """
  Liveness/readiness probe for load balancers: verifies the database connection.
  """
  use AkvyWeb, :controller

  @doc "Responds 200 with the instance id, or 503 if the database is unreachable."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(Akvy.Repo, "SELECT 1", []) do
      {:ok, _} ->
        json(conn, %{status: "ok", instance: Akvy.Instance.id()})

      {:error, _} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
