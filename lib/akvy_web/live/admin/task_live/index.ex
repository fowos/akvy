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
           String.t() => Task.status() | UUIDv7.t() | nil
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
  def handle_info({:akvy_task, %{id: id, event: event}}, socket) do
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
  @spec load_task(UUIDv7.t()) :: Task.t() | nil
  defp load_task(id) do
    case Tasks.get_task(id) do
      nil -> nil
      task -> Akvy.Repo.preload(task, :queue)
    end
  end

  @spec fetch(filters(), UUIDv7.t() | nil) :: [Task.t()]
  defp fetch(filters, cursor) do
    Tasks.list_tasks(%{
      status: filters["status"],
      queue_id: filters["queue_id"],
      api_key_id: filters["api_key_id"],
      before_id: cursor,
      limit: @page_size
    })
  end

  @spec cursor([Task.t()]) :: UUIDv7.t() | nil
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

  @spec valid_uuid(String.t() | nil) :: UUIDv7.t() | nil
  defp valid_uuid(nil), do: nil

  defp valid_uuid(value) do
    case UUIDv7.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
