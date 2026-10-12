defmodule AkvyWeb.Admin.ClusterLive do
  @moduledoc """
  Cluster page (`/admin/cluster`): per-node CPU, memory, FFmpeg slots and 24h activity.
  Refreshes every 3 s and on node up/down.
  """
  use AkvyWeb, :live_view

  alias Akvy.{Cluster, Stats}

  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_ms, :refresh)
      :net_kernel.monitor_nodes(true)
    end

    {:ok, socket |> assign(page_title: "Cluster") |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info({:nodeup, _node}, socket), do: {:noreply, load(socket)}
  def handle_info({:nodedown, _node}, socket), do: {:noreply, load(socket)}

  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load(socket) do
    nodes = Cluster.nodes_info()
    since = DateTime.add(DateTime.utc_now(), -24, :hour)
    processed = Map.new(Stats.nodes(since), &{&1.node, &1})

    assign(socket,
      nodes: nodes,
      summary: Cluster.summary(nodes),
      processed: processed,
      distributed?: node() != :nonode@nohost
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:cluster}>
      <.page_header title="Cluster" subtitle="Nodes discovered through the shared database">
        <:actions>
          <span class="inline-flex items-center gap-2 text-xs text-base-content/60">
            <span class="size-2 rounded-full bg-success animate-pulse" /> live · every 3s
          </span>
        </:actions>
      </.page_header>
      
      <div
        :if={!@distributed?}
        id="cluster-not-distributed"
        class="mb-6 flex gap-3 rounded-2xl border border-warning/30 bg-warning/5 p-4 text-sm"
      >
        <.icon name="hero-information-circle" class="size-5 shrink-0 text-warning" />
        <p>
          This node runs without Erlang distribution (development mode), so it cannot join a cluster.
          Releases start distributed and discover each other automatically.
        </p>
      </div>
      
      <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <.stat
          id="cluster-nodes"
          label="Nodes"
          value={@summary.reachable}
          icon="hero-server-stack"
          tone={if @summary.reachable == @summary.nodes, do: "success", else: "warning"}
          hint={"#{@summary.nodes - @summary.reachable} unreachable · #{@summary.schedulers} schedulers"}
        />
        <.stat
          id="cluster-ffmpeg"
          label="FFmpeg slots"
          value={"#{@summary.ffmpeg_running} / #{@summary.ffmpeg_limit}"}
          icon="hero-bolt"
          tone="primary"
          hint={"#{format_percent(@summary.ffmpeg_running, @summary.ffmpeg_limit)} busy"}
        />
        <.stat
          id="cluster-cpu"
          label="Average CPU"
          value={format_cpu(@summary.cpu_percent)}
          icon="hero-cpu-chip"
          tone="info"
          hint={"run queue #{@summary.run_queue}"}
        />
        <.stat
          id="cluster-memory"
          label="BEAM memory"
          value={format_bytes(@summary.beam_memory)}
          icon="hero-circle-stack"
          tone="neutral"
          hint="sum over nodes"
        />
      </div>
      
      <div id="cluster-node-list" class="mt-6 grid gap-6 xl:grid-cols-2">
        <.card :for={n <- @nodes} id={"node-#{dom_id(n.node)}"} class="overflow-hidden">
          <div class="flex items-start justify-between gap-4 border-b border-base-300 px-5 py-4">
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <span class={[
                  "size-2.5 rounded-full",
                  if(n.reachable, do: "bg-success", else: "bg-error")
                ]} />
                <p class="truncate font-semibold">{n.instance}</p>
                
                <span
                  :if={n.current?}
                  class="rounded-full bg-primary/10 px-2 py-0.5 text-[11px] font-medium text-primary"
                >
                  this node
                </span>
              </div>
              
              <p class="mt-1 truncate font-mono text-xs text-base-content/50">{n.node}</p>
            </div>
            
            <p :if={n.reachable} class="text-right text-xs text-base-content/50 whitespace-nowrap">
              up {format_ms(n.uptime_ms)}<br /> v{n.version} · OTP {n.otp_release}
            </p>
          </div>
          
          <%= if n.reachable do %>
            <div class="grid grid-cols-2 gap-px bg-base-300 sm:grid-cols-4">
              <.metric label="FFmpeg" value={"#{n.ffmpeg.running} / #{n.ffmpeg.limit}"}>
                <.meter value={n.ffmpeg.running} max={n.ffmpeg.limit} />
              </.metric>
              
              <.metric label="CPU" value={format_cpu(n.cpu_percent)}>
                <.meter value={n.cpu_percent || 0} max={100} />
              </.metric>
              
              <.metric
                label="Memory"
                value={
                  if n.system_memory_total,
                    do: format_bytes(n.system_memory_total - (n.system_memory_available || 0)),
                    else: "—"
                }
              >
                <.meter
                  value={(n.system_memory_total || 0) - (n.system_memory_available || 0)}
                  max={n.system_memory_total || 0}
                />
              </.metric>
              
              <.metric label="Load 1m" value={n.load1 || "—"}>
                <p class="text-[11px] text-base-content/40">{n.schedulers} schedulers</p>
              </.metric>
            </div>
            
            <div class="px-5 py-4">
              <div class="mb-2 flex items-center justify-between text-xs text-base-content/50">
                <span>Last 5 minutes</span>
                <span class="flex items-center gap-3">
                  <span class="flex items-center gap-1"><span class="size-2 rounded-sm bg-info/60" />
                  CPU</span>
                  <span class="flex items-center gap-1"><span class="size-2 rounded-sm bg-primary" />
                  ffmpeg slots</span>
                </span>
              </div>
              
              <.sparkline id={"spark-#{dom_id(n.node)}"} history={n.history} limit={n.ffmpeg.limit} />
            </div>
            
            <dl class="grid grid-cols-2 gap-x-6 gap-y-1.5 border-t border-base-300 px-5 py-3 text-xs sm:grid-cols-4">
              <div>
                <dt class="text-base-content/50">Processes</dt>
                
                <dd class="font-medium tabular-nums">{n.process_count}</dd>
              </div>
              
              <div>
                <dt class="text-base-content/50">Run queue</dt>
                
                <dd class="font-medium tabular-nums">{n.run_queue}</dd>
              </div>
              
              <div>
                <dt class="text-base-content/50">BEAM memory</dt>
                
                <dd class="font-medium tabular-nums">{format_bytes(n.beam_memory)}</dd>
              </div>
              
              <div>
                <dt class="text-base-content/50">Processed 24h</dt>
                
                <dd class="font-medium tabular-nums">
                  {(@processed[n.instance] && @processed[n.instance].processed) || 0}
                  <span
                    :if={@processed[n.instance] && @processed[n.instance].failed > 0}
                    class="text-error"
                  >
                    · {@processed[n.instance].failed} failed
                  </span>
                </dd>
              </div>
            </dl>
          <% else %>
            <p class="px-5 py-4 text-sm text-error">Unreachable: {n.error}</p>
          <% end %>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  slot :inner_block

  defp metric(assigns) do
    ~H"""
    <div class="bg-base-100 px-5 py-3">
      <p class="text-xs text-base-content/50">{@label}</p>
      
      <p class="mt-0.5 text-lg font-semibold tabular-nums">{@value}</p>
      
      <div class="mt-1.5">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :value, :any, required: true
  attr :max, :any, required: true

  defp meter(assigns) do
    pct = if assigns.max in [0, nil], do: 0, else: min(assigns.value * 100 / assigns.max, 100)
    assigns = assign(assigns, pct: pct)

    ~H"""
    <div class="h-1.5 w-full overflow-hidden rounded-full bg-base-200">
      <div
        class={[
          "h-full rounded-full transition-all duration-700",
          cond do
            @pct >= 90 -> "bg-error"
            @pct >= 70 -> "bg-warning"
            true -> "bg-primary"
          end
        ]}
        style={"width: #{Float.round(@pct * 1.0, 1)}%"}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :history, :list, required: true
  attr :limit, :integer, required: true

  defp sparkline(assigns) do
    ~H"""
    <div id={@id} class="flex h-14 items-end gap-[2px]">
      <div
        :for={s <- @history}
        class="relative flex h-full flex-1 flex-col justify-end"
        title={"#{Calendar.strftime(s.at, "%H:%M:%S")} · CPU #{format_cpu(s.cpu)} · ffmpeg #{s.ffmpeg}"}
      >
        <div
          class="w-full rounded-t-[2px] bg-info/60 transition-all duration-500"
          style={"height: #{s.cpu || 0}%"}
        />
        <div
          :if={s.ffmpeg > 0}
          class="absolute bottom-0 left-1/4 right-1/4 rounded-t-[2px] bg-primary"
          style={"height: #{if @limit > 0, do: min(s.ffmpeg * 100 / @limit, 100), else: 0}%"}
        />
      </div>
      
      <p :if={@history == []} class="text-xs text-base-content/40">Collecting samples…</p>
    </div>
    """
  end

  defp format_cpu(nil), do: "n/a"
  defp format_cpu(value), do: "#{Float.round(value * 1.0, 1)}%"

  @spec dom_id(atom() | String.t()) :: String.t()
  defp dom_id(node), do: node |> to_string() |> String.replace(~r/[^\w-]/, "-")
end
