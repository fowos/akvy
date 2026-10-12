defmodule AkvyWeb.Api.TaskControllerTest do
  use AkvyWeb.ConnCase, async: true

  import Akvy.ConversionFixtures

  alias Akvy.Storage.Local
  alias Akvy.Tasks
  alias Akvy.Workers.Convert

  setup %{conn: conn} do
    {api_key, raw_key} = api_key_fixture()
    queue = queue_fixture()

    conn = put_req_header(conn, "authorization", "Bearer " <> raw_key)
    %{conn: conn, api_key: api_key, raw_key: raw_key, queue: queue}
  end

  defp upload(content \\ "video bytes", content_type \\ "video/quicktime") do
    %{path: path} = upload_fixture(content)
    %Plug.Upload{path: path, filename: "clip.mov", content_type: content_type}
  end

  test "rejects requests without a valid API key", %{queue: queue} do
    conn = get(build_conn(), ~p"/api/v1/queues")
    assert json_response(conn, 401)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer akvy_nope")
      |> get(~p"/api/v1/tasks")

    assert json_response(conn, 401)
    assert queue
  end

  test "GET /queues lists enabled queues", %{conn: conn, queue: queue} do
    disabled = queue_fixture(%{enabled: false})

    ids =
      conn
      |> get(~p"/api/v1/queues")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.map(& &1["id"])

    assert queue.id in ids
    refute disabled.id in ids
  end

  describe "POST /queues/:queue_id/tasks" do
    test "uploads a file and enqueues the conversion", %{conn: conn, queue: queue} do
      conn = post(conn, ~p"/api/v1/queues/#{queue.id}/tasks", %{"file" => upload()})

      assert %{"id" => id, "status" => "uploaded", "links" => links} =
               json_response(conn, 202)["data"]

      assert links["events"] == "/api/v1/tasks/#{id}/events"
      assert_enqueued(worker: Convert, args: %{"task_id" => id})
      assert Local.exists?(Tasks.get_task!(id).input_key)
    end

    test "requires a file", %{conn: conn, queue: queue} do
      conn = post(conn, ~p"/api/v1/queues/#{queue.id}/tasks", %{})
      assert json_response(conn, 422)
    end

    test "returns 404 for unknown or disabled queues", %{conn: conn} do
      disabled = queue_fixture(%{enabled: false})

      assert conn
             |> post(~p"/api/v1/queues/#{disabled.id}/tasks", %{"file" => upload()})
             |> json_response(404)

      assert conn
             |> post(~p"/api/v1/queues/#{UUIDv7.generate()}/tasks", %{"file" => upload()})
             |> json_response(404)
    end

    test "enforces the queue content types", %{conn: conn} do
      queue = queue_fixture(%{allowed_content_types: ["audio/*"]})
      conn = post(conn, ~p"/api/v1/queues/#{queue.id}/tasks", %{"file" => upload()})
      assert json_response(conn, 415)
    end
  end

  describe "AkvyWeb.MultipartParser" do
    test "rejects bodies larger than the queue limit", %{raw_key: raw_key} do
      queue = queue_fixture(%{max_file_size_bytes: 10})
      boundary = "----akvy"
      body = multipart_body(boundary, String.duplicate("x", 200_000))

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        build_conn(:post, "/api/v1/queues/#{queue.id}/tasks", body)
        |> put_req_header("authorization", "Bearer " <> raw_key)
        |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
        |> put_req_header("content-length", to_string(byte_size(body)))
        |> AkvyWeb.Endpoint.call([])
      end
    end
  end

  defp multipart_body(boundary, content) do
    "--#{boundary}\r\n" <>
      ~s(Content-Disposition: form-data; name="file"; filename="a.mov"\r\n) <>
      "Content-Type: video/quicktime\r\n\r\n" <> content <> "\r\n--#{boundary}--\r\n"
  end

  test "GET /tasks/:id is scoped to the API key", %{conn: conn, api_key: api_key, queue: queue} do
    task = task_fixture(queue, api_key)
    other = task_fixture(queue)

    assert %{"id" => id} =
             conn |> get(~p"/api/v1/tasks/#{task.id}") |> json_response(200) |> Map.get("data")

    assert id == task.id
    assert conn |> get(~p"/api/v1/tasks/#{other.id}") |> json_response(404)
  end

  test "GET /tasks paginates with a cursor", %{conn: conn, api_key: api_key, queue: queue} do
    tasks = for _ <- 1..3, do: task_fixture(queue, api_key)

    page = conn |> get(~p"/api/v1/tasks?limit=2") |> json_response(200)
    assert length(page["data"]) == 2
    assert page["next_cursor"]

    page2 =
      conn |> get(~p"/api/v1/tasks?limit=2&cursor=#{page["next_cursor"]}") |> json_response(200)

    assert [%{"id" => last_id}] = page2["data"]
    assert last_id == hd(tasks).id
  end

  describe "GET /tasks/:id/result" do
    test "streams the result once and deletes it", %{conn: conn, api_key: api_key, queue: queue} do
      task = completed_task_fixture(queue, api_key)

      response = get(conn, ~p"/api/v1/tasks/#{task.id}/result")
      assert response.status == 200
      assert response.resp_body == "fake video content"
      assert [disposition] = get_resp_header(response, "content-disposition")
      assert disposition =~ ~s(filename="clip.mp4")

      task = Tasks.get_task!(task.id)
      assert task.status == :downloaded
      refute Local.exists?(task.output_key)

      assert conn |> get(~p"/api/v1/tasks/#{task.id}/result") |> json_response(410)
    end

    test "returns 409 while the conversion is running", %{
      conn: conn,
      api_key: api_key,
      queue: queue
    } do
      task = task_fixture(queue, api_key)
      assert conn |> get(~p"/api/v1/tasks/#{task.id}/result") |> json_response(409)
    end
  end

  test "DELETE /tasks/:id cancels the task", %{conn: conn, api_key: api_key, queue: queue} do
    task = task_fixture(queue, api_key)

    assert %{"status" => "cancelled"} =
             conn |> delete(~p"/api/v1/tasks/#{task.id}") |> json_response(200) |> Map.get("data")

    assert conn |> delete(~p"/api/v1/tasks/#{task.id}") |> json_response(409)
  end
end
