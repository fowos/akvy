defmodule AkvyWeb.Admin.TaskLive.Index do
  @moduledoc """
  Task list (`/admin/tasks`) with status/queue/API-key filters, cursor pagination and
  live updates over PubSub.
  """
  use AkvyWeb, :live_view

  alias Akvy.{ApiKeys, Queues, Tasks}
  alias Akvy.Tasks.Task

  @page_size 50

  @typep filters :: %{
           String.t() => Task.status() | Ecto.UUID.t() | nil
         }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tasks.subscribe_all()

    {:ok,
     assign(socket,
       page_title: "Tasks",
       queues: Queues.list_queues(),
       api_keys: ApiKeys.list_api_keys()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      "status" => valid_status(params["status"]),
      "queue_id" => valid_uuid(params["queue_id"]),
      "api_key_id" => valid_uuid(params["api_key_id"])
    }

    tasks = fetch(filters, nil)

    {:noreply,
     socket
     |> assign(filters: filters, filter_form: to_form(filters, as: :filters))
     |> assign(loaded_ids: MapSet.new(tasks, & &1.id), empty?: tasks == [])
     |> assign(cursor: cursor(tasks))
     |> stream(:tasks, tasks, reset: true)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    query = filters |> Enum.reject(fn {_, v} -> v in [nil, ""] end) |> Map.new()
    {:noreply, push_patch(socket, to: ~p"/admin/tasks?#{query}")}
  end

  def handle_event("load_more", _params, socket) do
    tasks = fetch(socket.assigns.filters, socket.assigns.cursor)

    {:noreply,
     socket
     |> assign(cursor: cursor(tasks))
     |> update(:loaded_ids, &Enum.into(tasks, &1, fn t -> t.id end))
     |> stream(:tasks, tasks)}
  end

  @impl true
  def handle_info({:akvy_task, %{"id" => id, "event" => event}}, socket) do
    cond do
      MapSet.member?(socket.assigns.loaded_ids, id) ->
        case load_task(id) do
          nil -> {:noreply, socket}
          task -> {:noreply, stream_insert(socket, :tasks, task)}
        end

      event == "uploaded" ->
        task = load_task(id)

        if task && matches?(task, socket.assigns.filters) do
          {:noreply,
           socket
           |> update(:loaded_ids, &MapSet.put(&1, id))
           |> assign(empty?: false)
           |> stream_insert(:tasks, task, at: 0)}
        else
          {:noreply, socket}
        end

      true ->
        {:noreply, socket}
    end
  end

  # The notification may outrun visibility of the row or refer to a removed task.
  @spec load_task(Ecto.UUID.t()) :: Task.t() | nil
  defp load_task(id) do
    case Tasks.get_task(id) do
      nil -> nil
      task -> Akvy.Repo.preload(task, :queue)
    end
  end

  @spec fetch(filters(), Ecto.UUID.t() | nil) :: [Task.t()]
  defp fetch(filters, cursor) do
    Tasks.list_tasks(%{
      status: filters["status"],
      queue_id: filters["queue_id"],
      api_key_id: filters["api_key_id"],
      before_id: cursor,
      limit: @page_size
    })
  end

  @spec cursor([Task.t()]) :: Ecto.UUID.t() | nil
  defp cursor(tasks) when length(tasks) == @page_size, do: List.last(tasks).id
  defp cursor(_tasks), do: nil

  @spec matches?(Task.t(), filters()) :: boolean()
  defp matches?(task, filters) do
    (is_nil(filters["status"]) or to_string(task.status) == to_string(filters["status"])) and
      (is_nil(filters["queue_id"]) or task.queue_id == filters["queue_id"]) and
      (is_nil(filters["api_key_id"]) or task.api_key_id == filters["api_key_id"])
  end

  @spec valid_status(String.t() | nil) :: Task.status() | nil
  defp valid_status(value), do: Enum.find(Task.statuses(), &(to_string(&1) == value))

  @spec valid_uuid(String.t() | nil) :: Ecto.UUID.t() | nil
  defp valid_uuid(nil), do: nil

  defp valid_uuid(value) do
    case UUIDv7.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:tasks}>
      <.page_header title="Tasks" subtitle="Live list of conversion tasks" />
      <.form
        for={@filter_form}
        id="task-filters"
        phx-change="filter"
        class="mb-4 grid gap-3 sm:grid-cols-3"
      >
        <.input
          field={@filter_form[:status]}
          type="select"
          prompt="All statuses"
          options={Enum.map(Task.statuses(), &{&1, &1})}
        />
        <.input
          field={@filter_form[:queue_id]}
          type="select"
          prompt="All queues"
          options={Enum.map(@queues, &{&1.name, &1.id})}
        />
        <.input
          field={@filter_form[:api_key_id]}
          type="select"
          prompt="All API keys"
          options={Enum.map(@api_keys, &{&1.name, &1.id})}
        />
      </.form>

      <.card class="overflow-hidden">
        <.empty_state :if={@empty?} id="tasks-empty" icon="hero-film" title="No tasks found">
          Tasks appear here as clients upload files.
        </.empty_state>

        <div :if={!@empty?} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="bg-base-200/50 text-xs text-base-content/50">
              <tr>
                <th class="px-5 py-2.5 text-left font-medium">File</th>

                <th class="px-3 py-2.5 text-left font-medium">Status</th>

                <th class="px-3 py-2.5 text-left font-medium">Queue</th>

                <th class="px-3 py-2.5 text-right font-medium">Size</th>

                <th class="px-3 py-2.5 text-right font-medium">FFmpeg</th>

                <th class="px-3 py-2.5 text-right font-medium">Total</th>

                <th class="px-5 py-2.5 text-right font-medium">Created</th>
              </tr>
            </thead>

            <tbody id="tasks" phx-update="stream">
              <tr
                :for={{dom_id, task} <- @streams.tasks}
                id={dom_id}
                phx-click={JS.navigate(~p"/admin/tasks/#{task.id}")}
                class="cursor-pointer border-t border-base-200 transition hover:bg-base-200/40"
              >
                <td class="px-5 py-3 max-w-xs">
                  <p class="truncate font-medium">{task.original_filename || "—"}</p>

                  <p class="font-mono text-[11px] text-base-content/40">{task.id}</p>
                </td>

                <td class="px-3 py-3">
                  <.status_badge status={task.status} />
                  <span :if={task.attempt > 1} class="ml-1 text-xs text-warning">
                    #{task.attempt}
                  </span>
                </td>

                <td class="px-3 py-3 text-base-content/70">{task.queue.name}</td>

                <td class="px-3 py-3 text-right tabular-nums text-base-content/70">
                  {format_bytes(task.input_size)}
                  <span :if={task.output_size} class="text-base-content/40">
                    → {format_bytes(task.output_size)}
                  </span>
                </td>

                <td class="px-3 py-3 text-right tabular-nums">{format_ms(task.ffmpeg_ms)}</td>

                <td class="px-3 py-3 text-right tabular-nums">{format_ms(task.total_ms)}</td>

                <td class="px-5 py-3 text-right text-xs text-base-content/50 whitespace-nowrap">
                  {format_relative(task.inserted_at)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>

      <div :if={@cursor} class="mt-4 flex justify-center">
        <button
          id="load-more"
          phx-click="load_more"
          phx-disable-with="Loading…"
          class="rounded-lg border border-base-300 bg-base-100 px-4 py-2 text-sm font-medium transition hover:bg-base-200"
        >
          Load more
        </button>
      </div>
    </Layouts.app>
    """
  end
end
