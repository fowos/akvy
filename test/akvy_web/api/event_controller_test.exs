defmodule AkvyWeb.Api.EventControllerTest do
  use AkvyWeb.ConnCase, async: true

  import Akvy.ConversionFixtures

  alias Akvy.Tasks

  setup do
    {api_key, raw_key} = api_key_fixture()
    %{api_key: api_key, raw_key: raw_key}
  end

  defp parse_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn chunk ->
      chunk
      |> String.split("\n")
      |> Map.new(fn line ->
        [key, value] = String.split(line, ": ", parts: 2)
        {key, value}
      end)
    end)
  end

  test "sends the snapshot and closes for finished tasks (key via query param)", %{
    api_key: api_key,
    raw_key: raw_key
  } do
    task = completed_task_fixture(nil, api_key)

    conn = get(build_conn(), ~p"/api/v1/tasks/#{task.id}/events?api_key=#{raw_key}")

    assert conn.status == 200
    assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
    assert [%{"event" => "task", "id" => seq, "data" => data}] = parse_events(conn.resp_body)
    assert seq == to_string(task.version)
    assert %{"event" => "snapshot", "status" => "completed", "id" => id} = Jason.decode!(data)
    assert id == task.id
  end

  test "streams live events until the task finishes", %{api_key: api_key, raw_key: raw_key} do
    task = task_fixture(nil, api_key)
    parent = self()

    stream =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Akvy.Repo, parent, self())

        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw_key)
        |> get(~p"/api/v1/tasks/#{task.id}/events")
      end)

    # Wait until the SSE process subscribed, then finish the task elsewhere.
    wait_for_subscriber(Tasks.task_topic(task.id))
    :ok = perform_job(Akvy.Workers.Convert, %{"task_id" => task.id})

    conn = Task.await(stream)
    events = conn.resp_body |> parse_events() |> Enum.map(&Jason.decode!(&1["data"])["event"])

    assert List.first(events) == "snapshot"
    assert "ffmpeg_finished" in events
    assert List.last(events) == "completed"
  end

  test "rejects unknown tasks", %{raw_key: raw_key} do
    conn = get(build_conn(), ~p"/api/v1/tasks/#{UUIDv7.generate()}/events?api_key=#{raw_key}")
    assert json_response(conn, 404)
  end

  defp wait_for_subscriber(topic, attempts \\ 100) do
    case Registry.lookup(Akvy.PubSub, topic) do
      [] when attempts > 0 ->
        receive do
        after
          10 -> wait_for_subscriber(topic, attempts - 1)
        end

      [] ->
        flunk("SSE stream did not subscribe")

      _ ->
        :ok
    end
  end
end
