defmodule AkvyWeb.Admin.DashboardLive do
  @moduledoc """
  Admin dashboard (`/admin`): task counts, throughput, stage timings, queues and
  cluster for the selected period. Refreshes every 5 s.
  """
  use AkvyWeb, :live_view

  alias Akvy.{Stats, Tasks}

  @refresh_ms 5_000

  @typep cluster_node :: %{
           instance: String.t(),
           online: boolean(),
           running: non_neg_integer(),
           limit: non_neg_integer(),
           processed: non_neg_integer(),
           avg_ffmpeg_ms: number() | nil
         }

  @typep cluster :: %{summary: map(), nodes: [cluster_node()]}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok, assign(socket, page_title: "Dashboard", period: "24h")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period =
      if params["period"] in Enum.map(periods(), &elem(&1, 0)), do: params["period"], else: "24h"

    {:noreply, socket |> assign(period: period) |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load(socket) do
    since = DateTime.add(DateTime.utc_now(), -period_hours(socket.assigns.period), :hour)
    overview = Stats.overview(since: since)
    by_status = overview.by_status
    succeeded = Enum.sum(for s <- Stats.success_statuses(), do: Map.get(by_status, s, 0))
    failed = Map.get(by_status, :failed, 0)

    averages = Map.new(overview.stages, fn {stage, row} -> {stage, row && row.avg} end)

    assign(socket,
      overview: overview,
      succeeded: succeeded,
      failed: failed,
      total: by_status |> Map.values() |> Enum.sum(),
      averages: averages,
      queues: Stats.per_queue(since),
      cluster: cluster(since),
      recent_failures: Tasks.list_tasks(%{status: :failed, since: since, limit: 5})
    )
  end

  # Live cluster members merged with instances that processed tasks in the period.
  @spec cluster(DateTime.t()) :: cluster()
  defp cluster(since) do
    live = Akvy.Cluster.nodes_info()
    processed = Map.new(Stats.nodes(since), &{&1.node, &1})

    online =
      for n <- live, n.reachable do
        stats = Map.get(processed, n.instance, %{})

        %{
          instance: n.instance,
          online: true,
          running: n.ffmpeg.running,
          limit: n.ffmpeg.limit,
          processed: Map.get(stats, :processed, 0),
          avg_ffmpeg_ms: Map.get(stats, :avg_ffmpeg_ms)
        }
      end

    online_ids = MapSet.new(online, & &1.instance)

    offline =
      for {id, stats} <- processed, not MapSet.member?(online_ids, id) do
        %{
          instance: id,
          online: false,
          running: 0,
          limit: 0,
          processed: stats.processed,
          avg_ffmpeg_ms: stats.avg_ffmpeg_ms
        }
      end

    %{summary: Akvy.Cluster.summary(live), nodes: online ++ Enum.sort_by(offline, & &1.instance)}
  end

  @spec format_cpu(number() | nil) :: String.t()
  defp format_cpu(nil), do: "n/a"
  defp format_cpu(value), do: "#{round(value)}%"

  @spec stage_name(atom()) :: String.t()
  defp stage_name(:total_ms), do: "Total"
  defp stage_name(:upload_ms), do: "Client upload → S3"
  defp stage_name(stage), do: stage_label(stage)
end
