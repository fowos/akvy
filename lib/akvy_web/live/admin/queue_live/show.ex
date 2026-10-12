defmodule AkvyWeb.Admin.QueueLive.Show do
  @moduledoc """
  Queue detail (`/admin/queues/:id`): configuration, period stats, stage timings and
  recent tasks. Refreshes every 5 s.
  """
  use AkvyWeb, :live_view

  alias Akvy.{Queues, Stats, Tasks}

  @refresh_ms 5_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)
    queue = Queues.get_queue!(id)
    {:ok, assign(socket, queue: queue, page_title: queue.name, period: "24h")}
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
    queue = socket.assigns.queue
    since = DateTime.add(DateTime.utc_now(), -period_hours(socket.assigns.period), :hour)
    overview = Stats.overview(since: since, queue_id: queue.id)
    succeeded = Enum.sum(for s <- Stats.success_statuses(), do: Map.get(overview.by_status, s, 0))

    assign(socket,
      overview: overview,
      succeeded: succeeded,
      failed: Map.get(overview.by_status, :failed, 0),
      averages: Map.new(overview.stages, fn {stage, row} -> {stage, row.avg} end),
      recent: Tasks.list_tasks(%{queue_id: queue.id, limit: 10})
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:queues}>
      <.link
        navigate={~p"/admin/queues"}
        class="mb-4 inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition"
      >
        <.icon name="hero-arrow-left" class="size-4" /> Queues
      </.link>
      <.page_header title={@queue.name} subtitle={@queue.description}>
        <:actions>
          <.period_tabs current={@period} path={&~p"/admin/queues/#{@queue}?period=#{&1}"} />
          <.link
            id="edit-queue"
            navigate={~p"/admin/queues/#{@queue}/edit"}
            class="inline-flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium transition hover:bg-base-200"
          >
            <.icon name="hero-pencil-square" class="size-4" /> Edit
          </.link>
        </:actions>
      </.page_header>

      <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <.stat
          id="queue-stat-active"
          label="In flight"
          value={@overview.in_flight.processing + @overview.in_flight.waiting}
          icon="hero-cog-6-tooth"
          tone="info"
          hint={"#{@overview.in_flight.processing} processing, #{@overview.in_flight.waiting} waiting"}
        />
        <.stat
          id="queue-stat-succeeded"
          label="Succeeded"
          value={@succeeded}
          icon="hero-check-circle"
          tone="success"
        />
        <.stat
          id="queue-stat-failed"
          label="Failed"
          value={@failed}
          icon="hero-x-circle"
          tone="error"
          hint={"failure rate #{format_percent(@failed, @succeeded + @failed)}"}
        />
        <.stat
          id="queue-stat-ffmpeg"
          label="p95 FFmpeg"
          value={format_ms(@overview.stages.ffmpeg_ms.p95)}
          icon="hero-bolt"
          tone="primary"
          hint={"avg #{format_ms(@overview.stages.ffmpeg_ms.avg)}"}
        />
      </div>

      <div class="mt-6 grid gap-6 lg:grid-cols-5">
        <.card title="Throughput" class="lg:col-span-3">
          <div class="p-5">
            <.throughput_chart id="queue-throughput" rows={@overview.throughput} />
          </div>
        </.card>
        <.card title="Average breakdown" class="lg:col-span-2">
          <div class="p-5">
            <.stage_bar id="queue-stage-bar" timings={@averages} />
          </div>
        </.card>
      </div>

      <div class="mt-6 grid gap-6 lg:grid-cols-5">
        <.card title="Recent tasks" class="lg:col-span-3 overflow-hidden">
          <:actions>
            <.link
              navigate={~p"/admin/tasks?queue_id=#{@queue.id}"}
              class="text-xs text-primary hover:underline"
            >
              View all
            </.link>
          </:actions>
          <.empty_state
            :if={@recent == []}
            id="queue-tasks-empty"
            icon="hero-film"
            title="No tasks yet"
          />
          <ul :if={@recent != []} id="queue-recent-tasks" class="divide-y divide-base-200">
            <li :for={task <- @recent}>
              <.link
                navigate={~p"/admin/tasks/#{task.id}"}
                class="flex items-center gap-4 px-5 py-3 hover:bg-base-200/40 transition"
              >
                <.status_badge status={task.status} />
                <span class="min-w-0 flex-1 truncate text-sm">{task.original_filename}</span>
                <span class="text-xs tabular-nums text-base-content/60">{format_ms(task.total_ms)}</span>
                <span class="w-20 text-right text-xs text-base-content/50">
                  {format_relative(task.inserted_at)}
                </span>
              </.link>
            </li>
          </ul>
        </.card>

        <.card title="Configuration" class="lg:col-span-2">
          <dl class="divide-y divide-base-200 text-sm">
            <div class="px-5 py-3">
              <dt class="text-xs text-base-content/50">Queue ID (for clients)</dt>
              <dd id="queue-id" class="mt-1 font-mono text-xs break-all">{@queue.id}</dd>
            </div>
            <div class="px-5 py-3">
              <dt class="text-xs text-base-content/50">Command</dt>
              <dd class="mt-1 rounded bg-base-200 px-2 py-1.5 font-mono text-xs break-all">
                ffmpeg {@queue.ffmpeg_args}
              </dd>
            </div>
            <.config_row
              label="Output"
              value={"*.#{@queue.output_extension} (#{@queue.output_content_type})"}
            />
            <.config_row label="Max upload" value={format_bytes(@queue.max_file_size_bytes)} />
            <.config_row
              label="Allowed types"
              value={
                if @queue.allowed_content_types == [],
                  do: "any",
                  else: Enum.join(@queue.allowed_content_types, ", ")
              }
            />
            <.config_row label="Timeout" value={format_ms(@queue.timeout_seconds * 1000)} />
            <.config_row label="Max attempts" value={@queue.max_attempts} />
            <.config_row label="Result TTL" value={format_ms(@queue.result_ttl_seconds * 1000)} />
            <.config_row label="Log retention" value={"#{@queue.log_retention_days} days"} />
            <.config_row label="Status" value={if @queue.enabled, do: "enabled", else: "disabled"} />
          </dl>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp config_row(assigns) do
    ~H"""
    <div class="flex justify-between gap-4 px-5 py-2.5">
      <dt class="text-base-content/60">{@label}</dt>
      <dd class="text-right font-medium">{@value}</dd>
    </div>
    """
  end
end
