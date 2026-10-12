defmodule Akvy.ConversionFixtures do
  @moduledoc """
  Test helpers for queues, API keys and tasks.
  """

  alias Akvy.{ApiKeys, Queues, Tasks}

  def valid_queue_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "queue-#{System.unique_integer([:positive])}",
      ffmpeg_args: "-i {input} -c:v libx264 {output}",
      output_extension: "mp4",
      output_content_type: "video/mp4",
      max_file_size_bytes: 10 * 1024 * 1024,
      result_ttl_seconds: 3600,
      max_attempts: 2,
      timeout_seconds: 60,
      log_retention_days: 7
    })
  end

  def queue_fixture(attrs \\ %{}) do
    {:ok, queue} = attrs |> valid_queue_attributes() |> Queues.create_queue()
    queue
  end

  @doc "Returns `{api_key, raw_key}`."
  def api_key_fixture(attrs \\ %{}) do
    {:ok, api_key, raw_key} =
      attrs
      |> Enum.into(%{name: "client-#{System.unique_integer([:positive])}"})
      |> ApiKeys.create_api_key()

    {api_key, raw_key}
  end

  def upload_fixture(content \\ "fake video content") do
    dir = Path.join(System.tmp_dir!(), "akvy_test_uploads")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{System.unique_integer([:positive])}.mov")
    File.write!(path, content)
    %{path: path, filename: "clip.mov", content_type: "video/quicktime"}
  end

  def task_fixture(queue \\ nil, api_key \\ nil) do
    queue = queue || queue_fixture()
    api_key = api_key || elem(api_key_fixture(), 0)
    {:ok, task} = Tasks.create_task(queue, api_key, upload_fixture())
    task
  end

  @doc "Runs the conversion job of the task to completion and returns the reloaded task."
  def completed_task_fixture(queue \\ nil, api_key \\ nil) do
    task = task_fixture(queue, api_key)
    :ok = Oban.Testing.perform_job(Akvy.Workers.Convert, %{"task_id" => task.id}, repo: Akvy.Repo)
    Tasks.get_task!(task.id)
  end
end
