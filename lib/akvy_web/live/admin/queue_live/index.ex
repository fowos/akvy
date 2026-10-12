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
end
