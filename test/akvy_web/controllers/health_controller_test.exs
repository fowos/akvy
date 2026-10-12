defmodule AkvyWeb.HealthControllerTest do
  use AkvyWeb.ConnCase, async: true

  test "GET /health reports the instance", %{conn: conn} do
    assert %{"status" => "ok", "instance" => instance} =
             conn |> get(~p"/health") |> json_response(200)

    assert instance == Akvy.Instance.id()
  end
end
