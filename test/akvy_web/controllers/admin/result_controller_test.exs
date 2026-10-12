defmodule AkvyWeb.Admin.ResultControllerTest do
  use AkvyWeb.ConnCase, async: true

  import Akvy.ConversionFixtures

  alias Akvy.Storage.Local
  alias Akvy.Tasks

  test "requires login", %{conn: conn} do
    task = completed_task_fixture()
    assert redirected_to(get(conn, ~p"/admin/tasks/#{task.id}/result")) == ~p"/users/log-in"
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "downloads the result without touching the client flow", %{conn: conn} do
      {api_key, raw_key} = api_key_fixture()
      task = completed_task_fixture(nil, api_key)

      response = get(conn, ~p"/admin/tasks/#{task.id}/result")
      assert response.status == 200
      assert response.resp_body == "fake video content"
      assert [disposition] = get_resp_header(response, "content-disposition")
      assert disposition =~ ~s(filename="clip.mp4")

      reloaded = Tasks.get_task!(task.id)
      assert reloaded.status == :completed
      assert reloaded.version == task.version
      assert Local.exists?(task.output_key)

      # The client still gets the file, and only then is it deleted.
      client =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw_key)
        |> get(~p"/api/v1/tasks/#{task.id}/result")

      assert client.status == 200
      assert Tasks.get_task!(task.id).status == :downloaded
      refute Local.exists?(task.output_key)
    end

    test "redirects when the result is not available", %{conn: conn} do
      task = task_fixture()

      conn = get(conn, ~p"/admin/tasks/#{task.id}/result")
      assert redirected_to(conn) == ~p"/admin/tasks/#{task.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer available"
    end
  end
end
