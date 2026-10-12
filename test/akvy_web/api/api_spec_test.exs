defmodule AkvyWeb.ApiSpecTest do
  use AkvyWeb.ConnCase, async: true

  test "serves the OpenAPI document", %{conn: conn} do
    spec = conn |> get(~p"/api/openapi") |> json_response(200)

    assert spec["openapi"] =~ "3."

    for path <- [
          "/api/v1/queues",
          "/api/v1/queues/{queue_id}/tasks",
          "/api/v1/tasks/{id}",
          "/api/v1/tasks/{id}/events",
          "/api/v1/tasks/{id}/result"
        ] do
      assert Map.has_key?(spec["paths"], path), "missing #{path}"
    end
  end

  test "documents authentication for every operation", %{conn: conn} do
    spec = conn |> get(~p"/api/openapi") |> json_response(200)

    assert spec["servers"] == [%{"url" => "/", "variables" => %{}}]

    assert %{"bearer" => %{"type" => "http"}, "api_key" => %{"in" => "query"}} =
             spec["components"]["securitySchemes"]

    for {path, ops} <- spec["paths"], {method, op} <- ops do
      assert [%{"bearer" => []} | _] = op["security"], "#{method} #{path} has no security"
      assert Map.has_key?(op["responses"], "401"), "#{method} #{path} has no 401"
    end
  end

  test "serves Swagger UI", %{conn: conn} do
    assert conn |> get(~p"/api/docs") |> html_response(200) =~ "swagger"
  end
end
