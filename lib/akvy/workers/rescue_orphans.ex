defmodule Akvy.Workers.RescueOrphans do
  @moduledoc """
  Recovers work owned by dead instances (runs every minute on the Oban leader).

  An instance boot is dead when its `Akvy.Heartbeat` is older than
  `Akvy.Heartbeat.stale_after/0` seconds. Then:

    * its executing conversion jobs are retried, or discarded on the last attempt,
      and the task history records the lost attempt;
    * its in-flight downloads are released so the client can download again.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Akvy.{Heartbeat, Recovery, Repo}
  alias Akvy.Tasks.{Task, TaskEvent}

  @batch 100
  # Leaves a fresh boot time to write its first heartbeat.
  @grace_seconds 30
  @heartbeat_retention_seconds 24 * 60 * 60

  # Database time, so it is comparable with heartbeats regardless of app clock skew.
  defmacrop db_ago(seconds) do
    quote do
      fragment("(now() AT TIME ZONE 'utc') - make_interval(secs => ?)", unquote(seconds))
    end
  end

  @impl Oban.Worker
  def perform(_job) do
    rescue_jobs()
    release_downloads()
    prune_heartbeats()
    :ok
  end

  @spec rescue_jobs() :: :ok
  defp rescue_jobs do
    worker = inspect(Akvy.Workers.Convert)

    alive_producer =
      from h in "instance_heartbeats",
        where:
          fragment("?::text", h.producer_uuid) == fragment("?[2]", parent_as(:job).attempted_by) and
            h.seen_at > db_ago(^Heartbeat.stale_after()),
        select: 1

    from(j in Oban.Job,
      as: :job,
      where: j.worker == ^worker and j.state == "executing",
      where: j.attempted_at < db_ago(^@grace_seconds),
      where: not exists(alive_producer),
      limit: @batch
    )
    |> Repo.all()
    |> Enum.each(&rescue_job/1)
  end

  @spec rescue_job(Oban.Job.t()) :: :ok
  defp rescue_job(%Oban.Job{} = job) do
    instance = List.first(job.attempted_by || []) || "unknown"
    Recovery.release_job(job, "instance #{instance} stopped responding")
  end

  # The last event of a downloading task is `download_started`; it names the instance
  # serving the download. The download is lost when that instance's boot is dead.
  @spec release_downloads() :: :ok
  defp release_downloads do
    alive_server =
      from h in "instance_heartbeats",
        where:
          h.instance == parent_as(:event).node and
            h.started_at <= parent_as(:event).occurred_at and
            h.seen_at > db_ago(^Heartbeat.stale_after()),
        select: 1

    from(t in Task,
      join: e in TaskEvent,
      as: :event,
      on: e.task_id == t.id and e.seq == t.version,
      where: t.status == :downloading and e.type == :download_started,
      where: e.occurred_at < db_ago(^@grace_seconds),
      where: not exists(alive_server),
      limit: @batch
    )
    |> Repo.all()
    |> Enum.each(&Recovery.release_download(&1, "serving instance stopped responding"))
  end

  @spec prune_heartbeats() :: :ok
  defp prune_heartbeats do
    Repo.delete_all(
      from h in "instance_heartbeats", where: h.seen_at < db_ago(^@heartbeat_retention_seconds)
    )

    :ok
  end
end
