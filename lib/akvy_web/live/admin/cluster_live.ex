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

  @spec format_cpu(number() | nil) :: String.t()
  defp format_cpu(nil), do: "n/a"
  defp format_cpu(value), do: "#{Float.round(value * 1.0, 1)}%"

  @spec dom_id(atom() | String.t()) :: String.t()
  defp dom_id(node), do: node |> to_string() |> String.replace(~r/[^\w-]/, "-")
end
