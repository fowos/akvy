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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:dashboard}>
      <.page_header title="Dashboard" subtitle="Conversion activity across all instances">
        <:actions>
          <.period_tabs current={@period} path={&~p"/admin?period=#{&1}"} />
        </:actions>
      </.page_header>
      
      <div class="grid grid-cols-2 gap-4 lg:grid-cols-5">
        <.stat
          id="stat-processing"
          label="Processing now"
          value={@overview.in_flight.processing}
          icon="hero-cog-6-tooth"
          tone="info"
          hint={"#{@cluster.summary.ffmpeg_running} of #{@cluster.summary.ffmpeg_limit} ffmpeg slots busy"}
        />
        <.stat
          id="stat-waiting"
          label="Waiting"
          value={@overview.in_flight.waiting}
          icon="hero-clock"
          tone="neutral"
          hint="queued or retrying"
        />
        <.stat
          id="stat-succeeded"
          label="Succeeded"
          value={@succeeded}
          icon="hero-check-circle"
          tone="success"
          hint={"of #{@total} uploaded in #{@period}"}
        />
        <.stat
          id="stat-failed"
          label="Failed"
          value={@failed}
          icon="hero-x-circle"
          tone="error"
          hint={"failure rate #{format_percent(@failed, @succeeded + @failed)}"}
        />
        <.stat
          id="stat-retried"
          label="Retried"
          value={@overview.retried}
          icon="hero-arrow-path"
          tone="warning"
          hint="needed more than one attempt"
        />
      </div>
      
      <div class="mt-6 grid gap-6 lg:grid-cols-5">
        <.card title="Throughput" class="lg:col-span-3">
          <:actions>
            <span class="flex items-center gap-3 text-xs text-base-content/60">
              <span class="flex items-center gap-1">
                <span class="size-2 rounded-sm bg-primary/70" /> succeeded
              </span>
              
              <span class="flex items-center gap-1"><span class="size-2 rounded-sm bg-error/70" />
              failed</span>
            </span>
          </:actions>
          
          <div class="p-5">
            <.throughput_chart id="throughput-chart" rows={@overview.throughput} />
          </div>
        </.card>
        
        <.card title="Where time goes (average)" class="lg:col-span-2">
          <div class="p-5 space-y-5">
            <.stage_bar id="avg-stage-bar" timings={@averages} />
            <table class="w-full text-sm">
              <thead class="text-xs text-base-content/50">
                <tr>
                  <th class="text-left font-normal pb-2">Stage</th>
                  
                  <th class="text-right font-normal pb-2">avg</th>
                  
                  <th class="text-right font-normal pb-2">p50</th>
                  
                  <th class="text-right font-normal pb-2">p95</th>
                </tr>
              </thead>
              
              <tbody class="tabular-nums">
                <tr
                  :for={
                    stage <-
                      ~w(upload_ms queue_wait_ms s3_download_ms ffmpeg_ms s3_upload_ms total_ms)a
                  }
                  class="border-t border-base-200"
                >
                  <td class="py-1.5 text-base-content/70">{stage_name(stage)}</td>
                  
                  <td class="py-1.5 text-right">{format_ms(@overview.stages[stage].avg)}</td>
                  
                  <td class="py-1.5 text-right">{format_ms(@overview.stages[stage].p50)}</td>
                  
                  <td class="py-1.5 text-right">{format_ms(@overview.stages[stage].p95)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
      
      <div class="mt-6 grid gap-6 lg:grid-cols-5">
        <.card title="Queues" class="lg:col-span-3 overflow-hidden">
          <:actions>
            <.link navigate={~p"/admin/queues"} class="text-xs text-primary hover:underline">
              Manage
            </.link>
          </:actions>
          
          <%= if @queues == [] do %>
            <.empty_state id="queues-empty" icon="hero-queue-list" title="No queues yet">
              <.link navigate={~p"/admin/queues/new"} class="text-primary hover:underline">
                Create the first queue
              </.link>
            </.empty_state>
          <% else %>
            <div class="overflow-x-auto">
              <table id="dashboard-queues" class="w-full text-sm">
                <thead class="bg-base-200/50 text-xs text-base-content/50">
                  <tr>
                    <th class="px-5 py-2 text-left font-medium">Queue</th>
                    
                    <th class="px-3 py-2 text-right font-medium">Active</th>
                    
                    <th class="px-3 py-2 text-right font-medium">Done</th>
                    
                    <th class="px-3 py-2 text-right font-medium">Failed</th>
                    
                    <th class="px-3 py-2 text-right font-medium">avg ffmpeg</th>
                    
                    <th class="px-5 py-2 text-right font-medium">p95 total</th>
                  </tr>
                </thead>
                
                <tbody class="tabular-nums">
                  <tr
                    :for={row <- @queues}
                    class="border-t border-base-200 hover:bg-base-200/40 transition"
                  >
                    <td class="px-5 py-2.5">
                      <.link
                        navigate={~p"/admin/queues/#{row.queue}"}
                        class="font-medium hover:text-primary"
                      >
                        {row.queue.name}
                      </.link>
                      
                      <span :if={!row.queue.enabled} class="ml-1 text-xs text-base-content/40">
                        disabled
                      </span>
                    </td>
                    
                    <td class="px-3 py-2.5 text-right">{row.active}</td>
                    
                    <td class="px-3 py-2.5 text-right text-success">{row.succeeded}</td>
                    
                    <td class="px-3 py-2.5 text-right text-error">{row.failed}</td>
                    
                    <td class="px-3 py-2.5 text-right">{format_ms(row.avg_ffmpeg_ms)}</td>
                    
                    <td class="px-5 py-2.5 text-right">{format_ms(row.p95_total_ms)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </.card>
        
        <.card title="Cluster" class="lg:col-span-2 overflow-hidden">
          <:actions>
            <.link navigate={~p"/admin/cluster"} class="text-xs text-primary hover:underline">
              Details
            </.link>
          </:actions>
          
          <div class="grid grid-cols-3 divide-x divide-base-200 border-b border-base-200 text-center">
            <div class="px-3 py-3">
              <p id="dashboard-cluster-nodes" class="text-xl font-semibold tabular-nums">
                {@cluster.summary.reachable}
              </p>
              
              <p class="text-xs text-base-content/50">nodes online</p>
            </div>
            
            <div class="px-3 py-3">
              <p class="text-xl font-semibold tabular-nums">
                {@cluster.summary.ffmpeg_running}<span class="text-base-content/40">/{@cluster.summary.ffmpeg_limit}</span>
              </p>
              
              <p class="text-xs text-base-content/50">ffmpeg slots</p>
            </div>
            
            <div class="px-3 py-3">
              <p class="text-xl font-semibold tabular-nums">
                {format_cpu(@cluster.summary.cpu_percent)}
              </p>
              
              <p class="text-xs text-base-content/50">avg CPU</p>
            </div>
          </div>
          
          <ul id="dashboard-nodes" class="divide-y divide-base-200">
            <li :for={n <- @cluster.nodes} class="flex items-center gap-3 px-5 py-3">
              <span class={[
                "size-2 shrink-0 rounded-full",
                cond do
                  !n.online -> "bg-base-300"
                  n.running > 0 -> "bg-info animate-pulse"
                  true -> "bg-success"
                end
              ]} />
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-medium">
                  {n.instance}
                  <span :if={!n.online} class="text-xs font-normal text-base-content/40">offline</span>
                </p>
                
                <p class="text-xs text-base-content/50">
                  {n.processed} processed in {@period} · avg ffmpeg {format_ms(n.avg_ffmpeg_ms)}
                </p>
              </div>
              
              <div :if={n.online} class="w-20 text-right">
                <p class="text-xs tabular-nums">{n.running}/{n.limit}</p>
                
                <div class="mt-1 h-1 overflow-hidden rounded-full bg-base-200">
                  <div
                    class="h-full rounded-full bg-primary transition-all duration-700"
                    style={"width: #{if n.limit > 0, do: n.running * 100 / n.limit, else: 0}%"}
                  />
                </div>
              </div>
            </li>
          </ul>
        </.card>
      </div>
      
      <.card :if={@recent_failures != []} title="Recent failures" class="mt-6 overflow-hidden">
        <:actions>
          <.link
            navigate={~p"/admin/tasks?status=failed"}
            class="text-xs text-primary hover:underline"
          >
            View all
          </.link>
        </:actions>
        
        <ul id="recent-failures" class="divide-y divide-base-200">
          <li :for={task <- @recent_failures}>
            <.link
              navigate={~p"/admin/tasks/#{task.id}"}
              class="flex items-center gap-4 px-5 py-3 hover:bg-base-200/40 transition"
            >
              <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0" />
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-medium">{task.original_filename || task.id}</p>
                
                <p class="truncate text-xs text-base-content/60">{task.error}</p>
              </div>
              
              <span class="text-xs text-base-content/50 whitespace-nowrap">
                {task.queue.name} · {format_relative(task.finished_at)}
              </span>
            </.link>
          </li>
        </ul>
      </.card>
    </Layouts.app>
    """
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

  defp format_cpu(nil), do: "n/a"
  defp format_cpu(value), do: "#{round(value)}%"

  @spec stage_name(atom()) :: String.t()
  defp stage_name(:total_ms), do: "Total"
  defp stage_name(:upload_ms), do: "Client upload → S3"
  defp stage_name(stage), do: stage_label(stage)
end
