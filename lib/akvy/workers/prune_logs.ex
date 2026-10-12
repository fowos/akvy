defmodule Akvy.Workers.PruneLogs do
  @moduledoc """
  Deletes task logs older than the queue's `log_retention_days`, in batches to
  keep transactions and locks short. Events (history) are kept.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Akvy.{Queues, Repo}
  alias Akvy.Tasks.{Task, TaskLog}

  @batch 5_000

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    for queue <- Queues.list_queues() do
      threshold = DateTime.add(now, -queue.log_retention_days * 86_400, :second)
      prune(queue.id, threshold)
    end

    :ok
  end

  @doc "Deletes logs of the queue's tasks older than `threshold`. Returns the count."
  @spec prune(UUIDv7.t(), DateTime.t(), non_neg_integer()) :: non_neg_integer()
  def prune(queue_id, threshold, total \\ 0) do
    ids =
      from l in TaskLog,
        join: t in Task,
        on: t.id == l.task_id,
        where: t.queue_id == ^queue_id and l.inserted_at < ^threshold,
        select: l.id,
        limit: @batch

    case Repo.delete_all(from(l in TaskLog, where: l.id in subquery(ids))) do
      {0, _} -> total
      {count, _} when count < @batch -> total + count
      {count, _} -> prune(queue_id, threshold, total + count)
    end
  end
end
