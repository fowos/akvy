defmodule AkvyWeb.PageController do
  @moduledoc "Landing page."
  use AkvyWeb, :controller

  @doc "Redirects to the admin panel."
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    redirect(conn, to: ~p"/admin")
  end
end
