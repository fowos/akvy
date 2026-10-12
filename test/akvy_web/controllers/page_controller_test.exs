defmodule AkvyWeb.PageControllerTest do
  use AkvyWeb.ConnCase

  test "GET / redirects to the admin panel", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/admin"
  end
end
