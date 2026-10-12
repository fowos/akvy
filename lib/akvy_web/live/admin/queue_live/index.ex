defmodule AkvyWeb.Admin.QueueLive.Index do
  @moduledoc "Queue list (`/admin/queues`) with 24h stats and an enable/disable toggle."
  use AkvyWeb, :live_view

  alias Akvy.{Queues, Stats}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Queues") |> load()}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    queue = Queues.get_queue!(id)
    {:ok, _} = Queues.update_queue(queue, %{enabled: !queue.enabled})
    {:noreply, load(socket)}
  end

  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load(socket) do
    since = DateTime.add(DateTime.utc_now(), -24, :hour)
    rows = Stats.per_queue(since)

    socket
    |> assign(:empty?, rows == [])
    |> stream(:queues, Enum.map(rows, &Map.put(&1, :id, &1.queue.id)), reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:queues}>
      <.page_header title="Queues" subtitle="FFmpeg command templates, limits and retention">
        <:actions>
          <.link
            id="new-queue"
            navigate={~p"/admin/queues/new"}
            class="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110 active:scale-[.98]"
          >
            <.icon name="hero-plus" class="size-4" /> New queue
          </.link>
        </:actions>
      </.page_header>

      <.card class="overflow-hidden">
        <.empty_state :if={@empty?} id="queues-empty" icon="hero-queue-list" title="No queues yet">
          A queue defines the ffmpeg command applied to uploaded files.
        </.empty_state>
        <div :if={!@empty?} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="bg-base-200/50 text-xs text-base-content/50">
              <tr>
                <th class="px-5 py-2.5 text-left font-medium">Name</th>
                <th class="px-3 py-2.5 text-left font-medium">Command</th>
                <th class="px-3 py-2.5 text-right font-medium">Max size</th>
                <th class="px-3 py-2.5 text-right font-medium">TTL</th>
                <th class="px-3 py-2.5 text-right font-medium">24h done / failed</th>
                <th class="px-3 py-2.5 text-right font-medium">Enabled</th>
                <th class="px-5 py-2.5"><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody id="queues" phx-update="stream">
              <tr
                :for={{dom_id, row} <- @streams.queues}
                id={dom_id}
                class="border-t border-base-200 hover:bg-base-200/40 transition"
              >
                <td class="px-5 py-3">
                  <.link
                    navigate={~p"/admin/queues/#{row.queue}"}
                    class="font-medium hover:text-primary"
                  >
                    {row.queue.name}
                  </.link>
                  <p class="font-mono text-[11px] text-base-content/40">{row.queue.id}</p>
                </td>
                <td class="px-3 py-3 max-w-xs">
                  <code class="block truncate rounded bg-base-200 px-2 py-1 font-mono text-xs">
                    {row.queue.ffmpeg_args}
                  </code>
                </td>
                <td class="px-3 py-3 text-right tabular-nums">
                  {format_bytes(row.queue.max_file_size_bytes)}
                </td>
                <td class="px-3 py-3 text-right tabular-nums">
                  {format_ms(row.queue.result_ttl_seconds * 1000)}
                </td>
                <td class="px-3 py-3 text-right tabular-nums">
                  <span class="text-success">{row.succeeded}</span>
                  <span class="text-base-content/30">/</span>
                  <span class="text-error">{row.failed}</span>
                </td>
                <td class="px-3 py-3 text-right">
                  <input
                    id={"toggle-#{row.queue.id}"}
                    type="checkbox"
                    class="toggle toggle-sm toggle-primary"
                    checked={row.queue.enabled}
                    phx-click="toggle"
                    phx-value-id={row.queue.id}
                  />
                </td>
                <td class="px-5 py-3 text-right">
                  <.link
                    id={"edit-#{row.queue.id}"}
                    navigate={~p"/admin/queues/#{row.queue}/edit"}
                    title="Edit queue"
                    class="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-xs font-medium text-base-content/60 transition hover:bg-base-200 hover:text-primary"
                  >
                    <.icon name="hero-pencil-square" class="size-4" /> Edit
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
