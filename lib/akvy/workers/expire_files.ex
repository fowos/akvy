defmodule Akvy.Workers.ExpireFiles do
  @moduledoc """
  Periodic storage cleanup (runs on the Oban leader only):

    * completed results not downloaded before `expires_at` are deleted;
    * downloads interrupted by an instance crash are released;
    * source/result files left behind by failed or cancelled tasks are deleted;
    * tasks whose conversion job no longer exists are marked as failed.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query
  require Logger

  alias Akvy.{Repo, Tasks}
  alias Akvy.Tasks.Task

  @batch 200
  @stuck_download_after_seconds 6 * 60 * 60
  @orphan_after_seconds 10 * 60

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    expire_results(now)
    release_stuck_downloads(now)
    cleanup_leftovers()
    fail_orphans(now)
    :ok
  end

  @spec expire_results(DateTime.t()) :: :ok
  defp expire_results(now) do
    from(t in Task, where: t.status == :completed and t.expires_at < ^now, limit: @batch)
    |> Repo.all()
    |> Enum.each(fn task ->
      with {:ok, task, _} <- Tasks.record(task, :expired),
           {:ok, _task} <- Tasks.delete_output(task) do
        :ok
      else
        error -> Logger.warning("expire #{task.id} failed: #{inspect(error)}")
      end
    end)
  end

  @spec release_stuck_downloads(DateTime.t()) :: :ok
  defp release_stuck_downloads(now) do
    threshold = DateTime.add(now, -@stuck_download_after_seconds, :second)

    from(t in Task, where: t.status == :downloading and t.updated_at < ^threshold, limit: @batch)
    |> Repo.all()
    |> Enum.each(&Tasks.abort_download/1)
  end

  @spec cleanup_leftovers() :: :ok
  defp cleanup_leftovers do
    from(t in Task,
      where:
        t.status in [:failed, :cancelled, :expired, :downloaded] and
          ((not is_nil(t.input_key) and is_nil(t.input_deleted_at)) or
             (not is_nil(t.output_key) and is_nil(t.output_deleted_at))),
      limit: @batch
    )
    |> Repo.all()
    |> Enum.each(fn task ->
      with {:ok, task} <- Tasks.delete_input(task), {:ok, _} <- Tasks.delete_output(task) do
        :ok
      else
        error -> Logger.warning("cleanup #{task.id} failed: #{inspect(error)}")
      end
    end)
  end

  # Last-resort net: an active task always has a live job (both are written in one
  # transaction, failures are recorded before the job ends), so a task without one
  # means the job was lost some other way, e.g. deleted manually.
  @spec fail_orphans(DateTime.t()) :: :ok
  defp fail_orphans(now) do
    threshold = DateTime.add(now, -@orphan_after_seconds, :second)
    worker = inspect(Akvy.Workers.Convert)

    live_job =
      from j in Oban.Job,
        where:
          j.worker == ^worker and
            j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("?->>'task_id'", j.args) == type(parent_as(:task).id, :string)

    from(t in Task,
      as: :task,
      where: t.status in ^Task.active_statuses() and t.updated_at < ^threshold,
      where: not exists(live_job),
      limit: @batch
    )
    |> Repo.all()
    |> Enum.each(fn task ->
      with {:ok, task, _} <-
             Tasks.record(task, :failed, data: %{"error" => "conversion job lost"}),
           {:ok, _} <- Tasks.delete_input(task) do
        :ok
      end
    end)
  end
end
