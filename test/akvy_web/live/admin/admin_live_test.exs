defmodule AkvyWeb.Admin.AdminLiveTest do
  use AkvyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Akvy.ConversionFixtures

  alias Akvy.Queues

  test "admin pages require login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin")
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "dashboard shows statistics", %{conn: conn} do
      queue = queue_fixture()
      completed_task_fixture(queue)

      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#stat-processing")
      assert has_element?(view, "#stat-succeeded", "1")
      assert has_element?(view, "#throughput-chart")
      assert has_element?(view, "#avg-stage-bar")
      assert has_element?(view, "#dashboard-queues", queue.name)
      assert has_element?(view, "#dashboard-nodes", Akvy.Instance.id())
      assert has_element?(view, "#dashboard-cluster-nodes", "1")

      view |> element("#period-tabs a", "7d") |> render_click()
      assert_patch(view, ~p"/admin?period=7d")
    end

    test "creates a queue", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/queues/new")

      assert view
             |> form("#queue-form", queue: %{name: "x", ffmpeg_args: "-i {input}"})
             |> render_change() =~ "must contain {output}"

      assert has_element?(view, "#queue-form")

      {:ok, _view, html} =
        view
        |> form("#queue-form",
          queue: %{
            name: "h264",
            ffmpeg_args: "-i {input} -c:v libx264 {output}",
            output_extension: "mp4",
            output_content_type: "video/mp4",
            max_file_size_mb: "100",
            result_ttl_hours: "12",
            allowed_content_types: "video/*, audio/mpeg",
            timeout_seconds: "600",
            max_attempts: "3",
            log_retention_days: "7"
          }
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Queue saved"
      queue = Enum.find(Queues.list_queues(), &(&1.name == "h264"))
      assert queue.max_file_size_bytes == 100 * 1024 * 1024
      assert queue.result_ttl_seconds == 12 * 3600
      assert queue.allowed_content_types == ["video/*", "audio/mpeg"]
    end

    test "queue page shows configuration and stats", %{conn: conn} do
      queue = queue_fixture()
      completed_task_fixture(queue)

      {:ok, view, _html} = live(conn, ~p"/admin/queues/#{queue}")
      assert has_element?(view, "#queue-id", queue.id)
      assert has_element?(view, "#queue-stat-succeeded", "1")
      assert has_element?(view, "#queue-recent-tasks")
    end

    test "uploads a file into the queue on behalf of an API key", %{conn: conn} do
      queue = queue_fixture()
      {api_key, _raw} = api_key_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/queues/#{queue}")

      file =
        file_input(view, "#upload-form", :file, [
          %{name: "movie.mov", content: "admin upload", type: "video/quicktime"}
        ])

      assert render_upload(file, "movie.mov") =~ "movie.mov"

      {:ok, _view, _html} =
        view
        |> form("#upload-form", upload: %{api_key_id: api_key.id})
        |> render_submit()
        |> follow_redirect(conn)

      assert [task] = Akvy.Tasks.list_tasks(%{queue_id: queue.id})
      assert task.original_filename == "movie.mov"
      assert task.api_key_id == api_key.id
      assert task.status == :uploaded
    end

    test "rejects a file type the queue does not accept", %{conn: conn} do
      queue = queue_fixture(%{allowed_content_types: ["video/*"]})
      {:ok, view, _html} = live(conn, ~p"/admin/queues/#{queue}")

      file =
        file_input(view, "#upload-form", :file, [
          %{name: "notes.txt", content: "text", type: "text/plain"}
        ])

      render_upload(file, "notes.txt")
      html = view |> form("#upload-form") |> render_submit()

      assert html =~ "not accepted"
      assert Akvy.Tasks.list_tasks(%{queue_id: queue.id}) == []
    end

    test "task page offers the result download while the file exists", %{conn: conn} do
      task = completed_task_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/tasks/#{task.id}")
      assert has_element?(view, ~s(#download-result[href="/admin/tasks/#{task.id}/result"]))

      {:ok, _} = Akvy.Tasks.cancel_task(task)
      {:ok, view, _html} = live(conn, ~p"/admin/tasks/#{task.id}")
      refute has_element?(view, "#download-result")
    end

    test "queues can be toggled from the list", %{conn: conn} do
      queue = queue_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/queues")

      view |> element("#toggle-#{queue.id}") |> render_click()
      refute Queues.get_queue!(queue.id).enabled
    end

    test "queues can be edited from the list", %{conn: conn} do
      queue = queue_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/queues")

      {:ok, view, _html} =
        view |> element("#edit-#{queue.id}") |> render_click() |> follow_redirect(conn)

      {:ok, _view, _html} =
        view
        |> form("#queue-form", queue: %{name: "renamed", max_file_size_mb: "5"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/admin/queues/#{queue}")

      queue = Queues.get_queue!(queue.id)
      assert queue.name == "renamed"
      assert queue.max_file_size_bytes == 5 * 1024 * 1024
    end

    test "task list filters and updates live", %{conn: conn} do
      queue = queue_fixture()
      task = task_fixture(queue)

      {:ok, view, _html} = live(conn, ~p"/admin/tasks")
      assert has_element?(view, "#tasks-#{task.id}")

      view |> form("#task-filters", filters: %{status: "failed"}) |> render_change()
      assert_patch(view, ~p"/admin/tasks?status=failed")
      refute has_element?(view, "#tasks-#{task.id}")

      {:ok, view, _html} = live(conn, ~p"/admin/tasks")
      new_task = task_fixture(queue)
      assert render(view) =~ new_task.id
      assert has_element?(view, "#tasks-#{new_task.id}")
    end

    test "task page shows the timeline, breakdown and logs", %{conn: conn} do
      task = completed_task_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin/tasks/#{task.id}")

      assert has_element?(view, "#task-stage-bar")
      assert has_element?(view, "#task-events")
      assert has_element?(view, "#task-events", "Completed")
      assert has_element?(view, "#task-logs")
      assert has_element?(view, "#task-ffmpeg")

      view |> element("#rebuild-task") |> render_click()
      assert render(view) =~ "Snapshot rebuilt"
    end

    test "cancels a task from its page", %{conn: conn} do
      task = task_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/tasks/#{task.id}")

      view |> element("#cancel-task") |> render_click()
      assert Akvy.Tasks.get_task!(task.id).status == :cancelled
    end

    test "cluster page shows nodes and load", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/cluster")

      assert has_element?(view, "#cluster-nodes", "1")
      assert has_element?(view, "#cluster-ffmpeg")
      assert has_element?(view, "#cluster-node-list", Akvy.Instance.id())
      assert has_element?(view, "#cluster-not-distributed")

      send(view.pid, :refresh)
      assert has_element?(view, "#cluster-cpu")
    end

    test "theme toggle offers system, light and dark", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      for theme <- ~w(system light dark) do
        assert has_element?(view, ~s(button[data-phx-theme="#{theme}"]))
      end
    end

    test "creates and revokes API keys", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

      view |> form("#api-key-form", api_key: %{name: "mobile"}) |> render_submit()
      assert has_element?(view, "#new-api-key-value")

      raw_key =
        view
        |> element("#new-api-key-value")
        |> render()
        |> then(&Regex.run(~r/akvy_[\w-]+/, &1))
        |> hd()

      api_key = Akvy.ApiKeys.authenticate(raw_key)
      assert api_key.name == "mobile"

      view |> element("#revoke-#{api_key.id}") |> render_click()
      assert Akvy.ApiKeys.authenticate(raw_key) == nil
    end
  end
end
