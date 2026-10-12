defmodule Akvy.QueuesTest do
  use Akvy.DataCase, async: true

  import Akvy.ConversionFixtures

  alias Akvy.Queues
  alias Akvy.Queues.Queue

  test "create_queue/1 with valid attributes" do
    assert {:ok, %Queue{} = queue} =
             Queues.create_queue(valid_queue_attributes(%{output_extension: ".MP4"}))

    assert queue.output_extension == "mp4"
    assert queue.enabled
    assert {:ok, _} = UUIDv7.cast(queue.id)
  end

  test "create_queue/1 validates the ffmpeg template and limits" do
    assert {:error, changeset} =
             Queues.create_queue(
               valid_queue_attributes(%{ffmpeg_args: "-i {input}", max_file_size_bytes: 0})
             )

    assert "must contain {output}" in errors_on(changeset).ffmpeg_args
    assert errors_on(changeset).max_file_size_bytes != []
  end

  test "names are unique" do
    queue = queue_fixture()
    assert {:error, changeset} = Queues.create_queue(valid_queue_attributes(%{name: queue.name}))
    assert "has already been taken" in errors_on(changeset).name
  end

  test "content_type_allowed?/2 supports wildcards" do
    queue = %Queue{allowed_content_types: ["video/*", "audio/mpeg"]}

    assert Queue.content_type_allowed?(queue, "video/mp4")
    assert Queue.content_type_allowed?(queue, "audio/mpeg")
    refute Queue.content_type_allowed?(queue, "image/png")
    assert Queue.content_type_allowed?(%Queue{allowed_content_types: []}, "anything/else")
  end

  test "get_queue/1 returns nil for malformed ids" do
    assert Queues.get_queue("not-a-uuid") == nil
  end

  test "delete_queue/1 refuses queues with tasks" do
    queue = queue_fixture()
    task_fixture(queue)
    assert {:error, _changeset} = Queues.delete_queue(queue)
  end
end
