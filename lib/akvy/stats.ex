defmodule Akvy.Stats do
  @moduledoc """
  Aggregated statistics for the admin panel, computed from the `tasks` snapshot
  table (indexed and denormalized for exactly this purpose).
  """
  import Ecto.Query

  alias Akvy.Repo
  alias Akvy.Tasks.Task

  @success [:completed, :downloading, :downloaded, :expired]
  @stages ~w(upload_ms queue_wait_ms s3_download_ms ffmpeg_ms s3_upload_ms processing_ms total_ms)a

  @typedoc "A duration column of `Akvy.Tasks.Task`."
  @type stage ::
          :upload_ms
          | :queue_wait_ms
          | :s3_download_ms
          | :ffmpeg_ms
          | :s3_upload_ms
          | :processing_ms
          | :total_ms

  @type queue_id :: UUIDv7.t() | nil

  @type option :: {:since, DateTime.t()} | {:queue_id, queue_id()}

  @type status_counts :: %{optional(Akvy.Tasks.Task.status()) => non_neg_integer()}

  @type in_flight :: %{waiting: non_neg_integer(), processing: non_neg_integer()}

  @typedoc "Duration statistics in milliseconds; all but `count` are nil when there is no data."
  @type stage_stat :: %{
          count: non_neg_integer(),
          avg: float() | nil,
          p50: float() | nil,
          p95: float() | nil,
          max: non_neg_integer() | nil
        }

  @type stage_stats :: %{stage() => stage_stat()}

  @type throughput_bucket :: %{
          bucket: DateTime.t(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer()
        }

  @type overview :: %{
          by_status: status_counts(),
          in_flight: in_flight(),
          stages: stage_stats(),
          throughput: [throughput_bucket()],
          retried: non_neg_integer()
        }

  @type queue_summary :: %{
          queue: Akvy.Queues.Queue.t(),
          total: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          active: non_neg_integer(),
          avg_ffmpeg_ms: float() | nil,
          p95_total_ms: float() | nil,
          input_bytes: non_neg_integer(),
          output_bytes: non_neg_integer()
        }

  @typedoc "Activity of one instance; `node` is the `Akvy.Instance` id."
  @type node_activity :: %{
          node: String.t(),
          executing: non_neg_integer(),
          processed: non_neg_integer(),
          failed: non_neg_integer(),
          avg_ffmpeg_ms: float() | nil,
          last_started_at: DateTime.t() | nil
        }

  @doc "Statuses counted as successful."
  @spec success_statuses() :: [Akvy.Tasks.Task.status()]
  def success_statuses, do: @success

  @doc "Duration columns, in pipeline order."
  @spec stages() :: [stage()]
  def stages, do: @stages

  @doc """
  Overview for a period. Options: `:since` (DateTime, required), `:queue_id`.
  """
  @spec overview([option()]) :: overview()
  def overview(opts) do
    since = Keyword.fetch!(opts, :since)
    queue_id = Keyword.get(opts, :queue_id)

    %{
      by_status: counts_by_status(since, queue_id),
      in_flight: in_flight(queue_id),
      stages: stage_stats(since, queue_id),
      throughput: throughput(since, queue_id),
      retried: retried_count(since, queue_id)
    }
  end

  @doc "Number of tasks per status created since `since`."
  @spec counts_by_status(DateTime.t(), queue_id()) :: status_counts()
  def counts_by_status(since, queue_id \\ nil) do
    Task
    |> where([t], t.inserted_at >= ^since)
    |> for_queue(queue_id)
    |> group_by([t], t.status)
    |> select([t], {t.status, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Tasks currently waiting and being processed (not limited by period)."
  @spec in_flight(queue_id()) :: in_flight()
  def in_flight(queue_id \\ nil) do
    counts =
      Task
      |> where([t], t.status in [:uploaded, :retrying, :processing])
      |> for_queue(queue_id)
      |> group_by([t], t.status)
      |> select([t], {t.status, count(t.id)})
      |> Repo.all()
      |> Map.new()

    %{
      waiting: Map.get(counts, :uploaded, 0) + Map.get(counts, :retrying, 0),
      processing: Map.get(counts, :processing, 0)
    }
  end

  @doc "avg / p50 / p95 / max of each stage for successful tasks finished since `since`."
  @spec stage_stats(DateTime.t(), queue_id()) :: stage_stats()
  def stage_stats(since, queue_id \\ nil) do
    base =
      Task
      |> where([t], t.status in ^@success and t.finished_at >= ^since)
      |> for_queue(queue_id)

    Map.new(@stages, fn stage ->
      row =
        base
        |> where([t], not is_nil(field(t, ^stage)))
        |> select([t], %{
          count: count(t.id),
          avg: type(avg(field(t, ^stage)), :float),
          p50:
            fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", field(t, ^stage))
            |> type(:float),
          p95:
            fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", field(t, ^stage))
            |> type(:float),
          max: max(field(t, ^stage))
        })
        |> Repo.one()

      {stage, row}
    end)
  end

  @doc """
  Successful and failed tasks per hour (per day for periods over 72h), oldest
  first; empty buckets are included.
  """
  @spec throughput(DateTime.t(), queue_id()) :: [throughput_bucket()]
  def throughput(since, queue_id \\ nil) do
    bucket = if DateTime.diff(DateTime.utc_now(), since, :hour) > 72, do: "day", else: "hour"

    finished =
      Task
      |> where([t], not is_nil(t.finished_at) and t.finished_at >= ^since)
      |> where([t], t.status in ^(@success ++ [:failed]))
      |> for_queue(queue_id)
      |> select([t], %{
        bucket: fragment("date_trunc(?, ?)", ^bucket, t.finished_at),
        failed: t.status == :failed
      })

    from(f in subquery(finished),
      group_by: f.bucket,
      order_by: f.bucket,
      select: %{
        bucket: f.bucket,
        succeeded: filter(count(), not f.failed),
        failed: filter(count(), f.failed)
      }
    )
    |> Repo.all()
    |> Enum.map(fn row -> %{row | bucket: DateTime.from_naive!(row.bucket, "Etc/UTC")} end)
    |> fill_buckets(since, bucket)
  end

  @spec fill_buckets([throughput_bucket()], DateTime.t(), String.t()) :: [throughput_bucket()]
  defp fill_buckets(rows, since, bucket) do
    step = if bucket == "day", do: 86_400, else: 3_600
    by_bucket = Map.new(rows, &{DateTime.to_unix(&1.bucket), &1})
    start = div(DateTime.to_unix(since), step) * step
    stop = div(DateTime.to_unix(DateTime.utc_now()), step) * step

    for ts <- start..stop//step do
      Map.get(by_bucket, ts, %{
        bucket: DateTime.from_unix!(ts) |> DateTime.add(0, :microsecond),
        succeeded: 0,
        failed: 0
      })
    end
  end

  @spec retried_count(DateTime.t(), UUIDv7.t() | nil) :: non_neg_integer()
  defp retried_count(since, queue_id) do
    Task
    |> where([t], t.inserted_at >= ^since and t.attempt > 1)
    |> for_queue(queue_id)
    |> select([t], count(t.id))
    |> Repo.one()
  end

  @doc "Per-queue summary of tasks created since `since`, ordered by queue name."
  @spec per_queue(DateTime.t()) :: [queue_summary()]
  def per_queue(since) do
    from(q in Akvy.Queues.Queue,
      left_join: t in Task,
      on: t.queue_id == q.id and t.inserted_at >= ^since,
      group_by: q.id,
      order_by: q.name,
      select: %{
        queue: q,
        total: count(t.id),
        succeeded: filter(count(t.id), t.status in ^@success),
        failed: filter(count(t.id), t.status == :failed),
        active: filter(count(t.id), t.status in [:uploaded, :retrying, :processing]),
        avg_ffmpeg_ms: type(avg(t.ffmpeg_ms), :float),
        p95_total_ms:
          fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", t.total_ms) |> type(:float),
        input_bytes: type(coalesce(sum(t.input_size), 0), :integer),
        output_bytes: type(coalesce(sum(t.output_size), 0), :integer)
      }
    )
    |> Repo.all()
  end

  @doc """
  Activity per instance: jobs executing right now (from Oban) and tasks the
  instance processed since `since`. Busiest instances first.
  """
  @spec nodes(DateTime.t()) :: [node_activity()]
  def nodes(since) do
    executing =
      from(j in Oban.Job,
        where: j.state == "executing" and j.queue == "convert",
        group_by: fragment("?[1]", j.attempted_by),
        select: {fragment("?[1]", j.attempted_by), count(j.id)}
      )
      |> Repo.all()
      |> Map.new()

    processed =
      from(t in Task,
        where: not is_nil(t.node) and t.started_at >= ^since,
        group_by: t.node,
        select:
          {t.node,
           %{
             processed: count(t.id),
             failed: filter(count(t.id), t.status == :failed),
             avg_ffmpeg_ms: type(avg(t.ffmpeg_ms), :float),
             last_started_at: max(t.started_at)
           }}
      )
      |> Repo.all()
      |> Map.new()

    (Map.keys(executing) ++ Map.keys(processed))
    |> Enum.uniq()
    |> Enum.map(fn node ->
      stats =
        Map.get(processed, node, %{
          processed: 0,
          failed: 0,
          avg_ffmpeg_ms: nil,
          last_started_at: nil
        })

      Map.merge(stats, %{node: node, executing: Map.get(executing, node, 0)})
    end)
    |> Enum.sort_by(&{-&1.executing, &1.node})
  end

  @spec for_queue(Ecto.Queryable.t(), UUIDv7.t() | nil) :: Ecto.Query.t()
  defp for_queue(query, nil), do: query
  defp for_queue(query, queue_id), do: where(query, [t], t.queue_id == ^queue_id)
end
