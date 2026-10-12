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

        <div class="space-y-6 lg:col-span-2">
          <.card title="Upload file">
            <.form
              for={@upload_form}
              id="upload-form"
              phx-change="validate_upload"
              phx-submit="upload"
              class="space-y-4 p-5"
            >
              <label
                for={@uploads.file.ref}
                id="upload-dropzone"
                phx-drop-target={@uploads.file.ref}
                class="flex cursor-pointer flex-col items-center gap-1.5 rounded-xl border-2 border-dashed border-base-300 px-4 py-6 text-center transition hover:border-primary hover:bg-primary/5"
              >
                <.icon name="hero-arrow-up-tray" class="size-6 text-base-content/40" />
                <span class="text-sm font-medium">Drop a file or click to choose</span>
                <span class="text-xs text-base-content/50">
                  up to {format_bytes(@queue.max_file_size_bytes)} · {allowed_types(@queue)}
                </span>
                <.live_file_input upload={@uploads.file} class="sr-only" />
              </label>

              <div
                :for={entry <- @uploads.file.entries}
                id={"upload-entry-#{entry.ref}"}
                class="rounded-lg bg-base-200/60 p-3 text-sm"
              >
                <div class="flex items-center gap-2">
                  <.icon name="hero-document" class="size-4 shrink-0 text-base-content/50" />
                  <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
                  <span class="text-xs tabular-nums text-base-content/60">
                    {format_bytes(entry.client_size)}
                  </span>
                  <button
                    type="button"
                    phx-click="cancel_upload"
                    phx-value-ref={entry.ref}
                    aria-label="Remove file"
                    class="rounded p-0.5 text-base-content/50 transition hover:bg-base-300 hover:text-base-content"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
                <div class="mt-2 h-1.5 overflow-hidden rounded-full bg-base-300">
                  <div
                    class="h-full rounded-full bg-primary transition-all duration-300"
                    style={"width: #{entry.progress}%"}
                  />
                </div>
                <p
                  :for={error <- upload_errors(@uploads.file, entry)}
                  class="mt-1.5 text-xs text-error"
                >
                  {upload_error(error)}
                </p>
                <p
                  :if={!Queue.content_type_allowed?(@queue, content_type(entry))}
                  class="mt-1.5 text-xs text-error"
                >
                  Content type {content_type(entry) || "unknown"} is not accepted by this queue
                </p>
              </div>

              <div>
                <.input
                  field={@upload_form[:api_key_id]}
                  type="select"
                  label="Owner (API key)"
                  prompt="None (admin only)"
                  options={Enum.map(@api_keys, &{&1.name, &1.id})}
                />
                <p class="text-xs text-base-content/60">
                  With an owner, the client can fetch the result and it is deleted after that
                  download. Without one, the result is kept until the TTL expires.
                </p>
              </div>

              <button
                id="upload-submit"
                type="submit"
                disabled={@uploads.file.entries == []}
                phx-disable-with="Uploading…"
                class="w-full rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110 active:scale-[.98] disabled:cursor-not-allowed disabled:opacity-50"
              >
                Upload and convert
              </button>
            </.form>
          </.card>

          <.card title="Configuration">
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
