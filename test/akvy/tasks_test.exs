defmodule Akvy.TasksTest do
  use Akvy.DataCase, async: true

  import Akvy.ConversionFixtures

  alias Akvy.Storage.Local
  alias Akvy.Tasks
  alias Akvy.Workers.Convert

  describe "create_task/3" do
    test "stores the file, writes the first events and enqueues the job" do
      queue = queue_fixture()
      {api_key, _} = api_key_fixture()
      Tasks.subscribe_api_key(api_key.id)

      assert {:ok, task} = Tasks.create_task(queue, api_key, upload_fixture("abc"))

      assert task.status == :uploaded
      assert task.version == 2
      assert task.input_size == 3
      assert task.upload_ms >= 0
      assert Local.exists?(task.input_key)
      assert [%{type: :uploaded, seq: 1}, %{type: :enqueued, seq: 2}] = Tasks.list_events(task.id)
      assert_enqueued(worker: Convert, args: %{"task_id" => task.id})
      assert_receive {:akvy_task, %{"id" => id, "event" => "enqueued"}}
      assert id == task.id
    end
  end

  describe "record/3" do
    test "rejects concurrent writers with a stale version" do
      task = task_fixture()

      assert {:ok, _task, _event} = Tasks.record(task, :attempt_started, attempt: 1)
      assert {:error, :stale} = Tasks.record(task, :attempt_started, attempt: 1)
    end

    test "rejects invalid transitions" do
      task = task_fixture()

      assert {:error, {:invalid_transition, :uploaded, :completed}} =
               Tasks.record(task, :completed)
    end
  end

  test "rebuild_snapshot/1 reproduces the live snapshot from history" do
    task = completed_task_fixture()

    assert {:ok, rebuilt} = Tasks.rebuild_snapshot(task.id)

    for field <- Akvy.Tasks.Task.__schema__(:fields) -- [:updated_at] do
      assert Map.get(rebuilt, field) == Map.get(task, field), "#{field} differs"
    end
  end

  describe "cancel_task/1" do
    test "cancels a queued task, its job and its files" do
      task = task_fixture()

      assert {:ok, task} = Tasks.cancel_task(task)
      assert task.status == :cancelled
      assert task.input_deleted_at
      refute Local.exists?(task.input_key)
      refute_enqueued(worker: Convert, args: %{"task_id" => task.id})
    end

    test "is not allowed after download" do
      task = completed_task_fixture()
      {:ok, task, _} = Tasks.start_download(task)
      {:ok, task} = Tasks.finish_download(task)

      assert {:error, {:invalid_transition, :downloaded, :cancelled}} = Tasks.cancel_task(task)
    end
  end

  test "download lifecycle deletes the result" do
    task = completed_task_fixture()
    assert Local.exists?(task.output_key)

    {:ok, task, _} = Tasks.start_download(task)

    assert {:error, {:invalid_transition, :downloading, :download_started}} =
             Tasks.start_download(task)

    {:ok, task} = Tasks.finish_download(task)
    assert task.status == :downloaded
    assert task.output_deleted_at
    refute Local.exists?(task.output_key)
  end
end
