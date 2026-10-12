defmodule AkvyWeb.Admin.QueueLive.Show do
  @moduledoc """
  Queue detail (`/admin/queues/:id`): configuration, period stats, stage timings and
  recent tasks; lets the admin upload a file into the queue. Refreshes every 5 s.
  """
  use AkvyWeb, :live_view

  alias Akvy.{ApiKeys, Queues, Stats, Tasks}
  alias Akvy.ApiKeys.ApiKey
  alias Akvy.Queues.Queue
  alias Phoenix.LiveView.UploadEntry

  @refresh_ms 5_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)
    queue = Queues.get_queue!(id)

    {:ok,
     socket
     |> assign(queue: queue, page_title: queue.name, period: "24h")
     |> assign(api_keys: Enum.filter(ApiKeys.list_api_keys(), &is_nil(&1.revoked_at)))
     |> assign(upload_form: to_form(%{"api_key_id" => ""}, as: :upload))
     |> allow_upload(:file,
       accept: :any,
       max_entries: 1,
       max_file_size: queue.max_file_size_bytes,
       chunk_size: 512_000
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period =
      if params["period"] in Enum.map(periods(), &elem(&1, 0)), do: params["period"], else: "24h"

    {:noreply, socket |> assign(period: period) |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("validate_upload", %{"upload" => params}, socket) do
    {:noreply, assign(socket, upload_form: to_form(params, as: :upload))}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :file, ref)}
  end

  def handle_event("upload", %{"upload" => params}, socket) do
    queue = socket.assigns.queue
    api_key = Enum.find(socket.assigns.api_keys, &(&1.id == params["api_key_id"]))

    results =
      consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
        {:ok, create_task(queue, api_key, path, entry)}
      end)

    case results do
      [{:ok, task}] ->
        {:noreply,
         socket
         |> put_flash(:info, "File uploaded, task created")
         |> push_navigate(to: ~p"/admin/tasks/#{task.id}")}

      [{:error, message}] when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      [{:error, _reason}] ->
        {:noreply, put_flash(socket, :error, "Storage is unavailable, retry later")}

      [] ->
        {:noreply, put_flash(socket, :error, "Choose a file first")}
    end
  end

  # Same content type check as the client API; disabled queues are allowed for testing.
  @spec create_task(Queue.t(), ApiKey.t() | nil, Path.t(), UploadEntry.t()) ::
          {:ok, Akvy.Tasks.Task.t()} | {:error, term()}
  defp create_task(queue, api_key, path, entry) do
    content_type = content_type(entry)

    if Queue.content_type_allowed?(queue, content_type) do
      Tasks.create_task(queue, api_key, %{
        path: path,
        filename: entry.client_name,
        content_type: content_type
      })
    else
      {:error, "Content type #{content_type || "unknown"} is not accepted by this queue"}
    end
  end

  @spec content_type(UploadEntry.t()) :: String.t() | nil
  defp content_type(%UploadEntry{client_type: type}) when type in [nil, ""], do: nil
  defp content_type(%UploadEntry{client_type: type}), do: type

  @spec allowed_types(Queue.t()) :: String.t()
  defp allowed_types(%Queue{allowed_content_types: []}), do: "any type"
  defp allowed_types(%Queue{allowed_content_types: types}), do: Enum.join(types, ", ")

  @spec upload_error(atom()) :: String.t()
  defp upload_error(:too_large), do: "File exceeds the queue limit"
  defp upload_error(:too_many_files), do: "Only one file at a time"
  defp upload_error(:not_accepted), do: "File type not accepted"
  defp upload_error(error), do: to_string(error)

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
