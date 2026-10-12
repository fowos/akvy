defmodule AkvyWeb.Admin.TaskLive.Show do
  @moduledoc """
  Task detail (`/admin/tasks/:id`): metadata, per-attempt timings, event timeline and
  FFmpeg logs. Updates live; supports cancel and snapshot rebuild.
  """
  use AkvyWeb, :live_view

  alias Akvy.{Repo, Tasks}
  alias Akvy.Tasks.TaskEvent

  @stage_events %{
    s3_download_finished: :s3_download_ms,
    ffmpeg_finished: :ffmpeg_ms,
    s3_upload_finished: :s3_upload_ms
  }

  @typep outcome :: :completed | :running | {:failed, String.t() | nil}

  @typep attempt :: %{
           number: pos_integer(),
           node: String.t() | nil,
           started_at: DateTime.t() | nil,
           outcome: outcome(),
           timings: %{atom() => non_neg_integer() | nil}
         }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Tasks.get_task(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Task not found")
         |> push_navigate(to: ~p"/admin/tasks")}

      task ->
        if connected?(socket), do: Tasks.subscribe_task(task.id)

        {:ok,
         socket
         |> assign(page_title: "Task #{String.slice(task.id, -8, 8)}", log_attempt: nil)
         |> load(task.id)}
    end
  end

  @impl true
  def handle_info({:akvy_task, _payload}, socket),
    do: {:noreply, load(socket, socket.assigns.task.id)}

  @impl true
  def handle_event("cancel", _params, socket) do
    case Tasks.cancel_task(socket.assigns.task) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Task cancelled") |> load(socket.assigns.task.id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot cancel: #{inspect(reason)}")}
    end
  end

  def handle_event("rebuild", _params, socket) do
    case Tasks.rebuild_snapshot(socket.assigns.task.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Snapshot rebuilt from history")
         |> load(socket.assigns.task.id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rebuild failed: #{inspect(reason)}")}
    end
  end

  def handle_event("log_attempt", %{"attempt" => attempt}, socket) do
    attempt = if attempt == "", do: nil, else: String.to_integer(attempt)
    {:noreply, socket |> assign(log_attempt: attempt) |> load_logs()}
  end

  @spec load(Phoenix.LiveView.Socket.t(), UUIDv7.t()) :: Phoenix.LiveView.Socket.t()
  defp load(socket, id) do
    task = id |> Tasks.get_task!() |> Repo.preload([:queue, :api_key])
    events = Tasks.list_events(id)

    socket
    |> assign(task: task, events: events, attempts: attempts(events))
    |> load_logs()
  end

  @spec load_logs(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_logs(socket) do
    logs = Tasks.list_logs(socket.assigns.task.id, attempt: socket.assigns.log_attempt)
    assign(socket, logs: logs, logs_pruned?: logs == [] and socket.assigns.task.attempt > 0)
  end

  # Per-attempt summary rebuilt from the event history.
  @spec attempts([TaskEvent.t()]) :: [attempt()]
  defp attempts(events) do
    events
    |> Enum.filter(&(&1.attempt > 0))
    |> Enum.group_by(& &1.attempt)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {attempt, events} ->
      started = Enum.find(events, &(&1.type == :attempt_started))
      last = List.last(events)

      outcome =
        cond do
          Enum.any?(events, &(&1.type == :completed)) ->
            :completed

          failed = Enum.find(events, &(&1.type == :attempt_failed)) ->
            {:failed, failed.data["error"]}

          true ->
            :running
        end

      timings =
        events
        |> Enum.flat_map(fn e ->
          case Map.fetch(@stage_events, e.type) do
            {:ok, key} -> [{key, e.duration_ms}]
            :error -> []
          end
        end)
        |> Map.new()
        |> Map.put(:queue_wait_ms, started && started.duration_ms)
        |> Map.put(
          :processing_ms,
          started && DateTime.diff(last.occurred_at, started.occurred_at, :millisecond)
        )

      %{
        number: attempt,
        node: started && started.node,
        started_at: started && started.occurred_at,
        outcome: outcome,
        timings: timings
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:tasks}>
      <.link
        navigate={~p"/admin/tasks"}
        class="mb-4 inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition"
      >
        <.icon name="hero-arrow-left" class="size-4" /> Tasks
      </.link>

      <div class="mb-8 flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="flex items-center gap-3">
            <h1 class="truncate text-2xl font-semibold tracking-tight">
              {@task.original_filename || "Untitled"}
            </h1>
            <.status_badge status={@task.status} />
          </div>
          <p class="mt-1 font-mono text-xs text-base-content/50">{@task.id}</p>
        </div>
        <div class="flex items-center gap-2">
          <.link
            :if={Tasks.result_available?(@task)}
            id="download-result"
            href={~p"/admin/tasks/#{@task.id}/result"}
            download
            title="Download without marking the task as downloaded; the client can still fetch it"
            class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110 active:scale-[.98]"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Download result
          </.link>
          <button
            :if={@task.status in [:uploaded, :retrying, :processing, :completed]}
            id="cancel-task"
            phx-click="cancel"
            data-confirm="Cancel this task and delete its files?"
            class="rounded-lg border border-error/30 px-3 py-1.5 text-sm font-medium text-error transition hover:bg-error/10"
          >
            Cancel task
          </button>
          <button
            id="rebuild-task"
            phx-click="rebuild"
            title="Recompute the snapshot from the event history"
            class="rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium transition hover:bg-base-200"
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
        </div>
      </div>

      <div
        :if={@task.error}
        id="task-error"
        class="mb-6 flex gap-3 rounded-2xl border border-error/30 bg-error/5 p-4 text-sm"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-error" />
        <p class="break-all">{@task.error}</p>
      </div>

      <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <.stat
          id="task-total"
          label="Total"
          value={format_ms(@task.total_ms)}
          icon="hero-clock"
          hint="upload → finished"
        />
        <.stat
          id="task-ffmpeg"
          label="FFmpeg"
          value={format_ms(@task.ffmpeg_ms)}
          icon="hero-bolt"
          tone="primary"
          hint={"exit code #{@task.exit_code || "—"}"}
        />
        <.stat
          id="task-transfer"
          label="S3 transfer"
          value={format_ms(sum_ms([@task.s3_download_ms, @task.s3_upload_ms]))}
          icon="hero-arrows-up-down"
          tone="info"
          hint={"↓ #{format_ms(@task.s3_download_ms)} · ↑ #{format_ms(@task.s3_upload_ms)}"}
        />
        <.stat
          id="task-attempts"
          label="Attempts"
          value={"#{@task.attempt} / #{@task.queue.max_attempts}"}
          icon="hero-arrow-path"
          tone={if @task.attempt > 1, do: "warning", else: "neutral"}
          hint={"last on #{@task.node || "—"}"}
        />
      </div>

      <.card title="Time breakdown (last attempt)" class="mt-6">
        <div class="p-5">
          <.stage_bar id="task-stage-bar" timings={Map.from_struct(@task)} />
        </div>
      </.card>

      <div class="mt-6 grid gap-6 lg:grid-cols-3">
        <div class="space-y-6 lg:col-span-2">
          <.card :if={length(@attempts) > 1} title="Attempts">
            <ul id="task-attempts-list" class="divide-y divide-base-200">
              <li :for={a <- @attempts} class="px-5 py-4">
                <div class="mb-3 flex flex-wrap items-center justify-between gap-2 text-sm">
                  <span class="font-medium">
                    Attempt {a.number}
                    <span class="font-mono text-xs text-base-content/50">on {a.node}</span>
                  </span>
                  <%= case a.outcome do %>
                    <% :completed -> %>
                      <span class="text-xs text-success">completed</span>
                    <% :running -> %>
                      <span class="text-xs text-info">running</span>
                    <% {:failed, error} -> %>
                      <span class="max-w-md truncate text-xs text-error">{error}</span>
                  <% end %>
                </div>
                <.stage_bar id={"attempt-bar-#{a.number}"} timings={a.timings} />
              </li>
            </ul>
          </.card>

          <.card title="History">
            <ol id="task-events" class="relative px-5 py-4">
              <li
                :for={event <- @events}
                id={"event-#{event.seq}"}
                class="relative flex gap-4 pb-4 last:pb-0"
              >
                <div class="flex flex-col items-center">
                  <span class={[
                    "mt-1.5 size-2.5 rounded-full ring-4 ring-base-100",
                    event_color(event.type)
                  ]} />
                  <span class="w-px flex-1 bg-base-300" />
                </div>
                <div class="min-w-0 flex-1 pb-1">
                  <div class="flex flex-wrap items-baseline justify-between gap-x-4">
                    <p class="text-sm font-medium">
                      {event_label(event.type)}
                      <span
                        :if={event.duration_ms}
                        class="ml-1 rounded bg-base-200 px-1.5 py-0.5 text-xs font-normal tabular-nums"
                      >
                        {format_ms(event.duration_ms)}
                      </span>
                    </p>
                    <p class="text-xs tabular-nums text-base-content/50">
                      {format_time(event.occurred_at)}
                      <span class="ml-1 text-base-content/40">+{format_ms(offset_ms(event, @task))}</span>
                    </p>
                  </div>
                  <p class="mt-0.5 text-xs text-base-content/50">
                    #{event.seq}
                    <span :if={event.attempt > 0}>· attempt {event.attempt}</span>
                    · <span class="font-mono">{event.node}</span>
                  </p>
                  <p :if={event_summary(event)} class="mt-1 break-all text-xs text-base-content/70">
                    {event_summary(event)}
                  </p>
                </div>
              </li>
            </ol>
          </.card>
        </div>

        <div class="space-y-6">
          <.card title="Details">
            <dl class="divide-y divide-base-200 text-sm">
              <.detail label="Queue">
                <.link
                  navigate={~p"/admin/queues/#{@task.queue}"}
                  class="text-primary hover:underline"
                >
                  {@task.queue.name}
                </.link>
              </.detail>
              <.detail label="API key">{(@task.api_key && @task.api_key.name) || "—"}</.detail>
              <.detail label="Content type">{@task.content_type || "—"}</.detail>
              <.detail label="Input">{format_bytes(@task.input_size)}</.detail>
              <.detail label="Output">{format_bytes(@task.output_size)}</.detail>
              <.detail label="Uploaded">{format_dt(@task.uploaded_at)}</.detail>
              <.detail label="Finished">{format_dt(@task.finished_at)}</.detail>
              <.detail label="Downloaded">{format_dt(@task.downloaded_at)}</.detail>
              <.detail label="Expires">{format_dt(@task.expires_at)}</.detail>
              <.detail label="Source file">
                {if @task.input_deleted_at,
                  do: "deleted #{format_relative(@task.input_deleted_at)}",
                  else: "stored"}
              </.detail>
              <.detail label="Result file">
                <%= cond do %>
                  <% @task.output_deleted_at -> %>
                    deleted {format_relative(@task.output_deleted_at)}
                  <% @task.output_key -> %>
                    stored
                  <% true -> %>
                    —
                <% end %>
              </.detail>
            </dl>
          </.card>
        </div>
      </div>

      <.card title="Logs" class="mt-6 overflow-hidden">
        <:actions>
          <form :if={@task.attempt > 1} id="log-attempt-form" phx-change="log_attempt">
            <select name="attempt" class="select select-xs">
              <option value="">All attempts</option>
              <option :for={n <- 1..@task.attempt} value={n} selected={@log_attempt == n}>
                Attempt {n}
              </option>
            </select>
          </form>
        </:actions>
        <%= cond do %>
          <% @logs != [] -> %>
            <div
              id="task-logs"
              class="max-h-[32rem] overflow-auto bg-neutral px-4 py-3 font-mono text-xs leading-5 text-neutral-content"
            >
              <div :for={log <- @logs} class={["flex gap-3", log.level == :error && "text-error"]}>
                <span class="shrink-0 select-none opacity-40">{log.attempt}</span>
                <span class="whitespace-pre-wrap break-all">{log.message}</span>
              </div>
            </div>
          <% @logs_pruned? -> %>
            <.empty_state
              id="logs-pruned"
              icon="hero-archive-box-x-mark"
              title="Logs are not available"
            >
              They were removed by the retention policy ({@task.queue.log_retention_days} days).
            </.empty_state>
          <% true -> %>
            <.empty_state id="logs-empty" icon="hero-document-text" title="No logs yet" />
        <% end %>
      </.card>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div class="flex justify-between gap-4 px-5 py-2.5">
      <dt class="text-base-content/60">{@label}</dt>
      <dd class="text-right">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @spec sum_ms([non_neg_integer() | nil]) :: non_neg_integer() | nil
  defp sum_ms(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      list -> Enum.sum(list)
    end
  end

  @spec offset_ms(TaskEvent.t(), Akvy.Tasks.Task.t()) :: non_neg_integer() | nil
  defp offset_ms(event, %{uploaded_at: %DateTime{} = uploaded}),
    do: max(DateTime.diff(event.occurred_at, uploaded, :millisecond), 0)

  defp offset_ms(_event, _task), do: nil

  @spec event_label(atom()) :: String.t()
  defp event_label(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
    |> String.replace("Ffmpeg", "FFmpeg")
  end

  @spec event_color(atom()) :: String.t()
  defp event_color(type) when type in [:completed, :downloaded], do: "bg-success"
  defp event_color(type) when type in [:failed, :attempt_failed], do: "bg-error"
  defp event_color(type) when type in [:retry_scheduled, :download_aborted], do: "bg-warning"
  defp event_color(type) when type in [:ffmpeg_started, :ffmpeg_finished], do: "bg-violet-500"

  defp event_color(type)
       when type in [
              :s3_download_started,
              :s3_download_finished,
              :s3_upload_started,
              :s3_upload_finished
            ],
       do: "bg-sky-500"

  defp event_color(type) when type in [:cancelled, :expired, :input_deleted, :output_deleted],
    do: "bg-base-content/30"

  defp event_color(_type), do: "bg-primary"

  @spec event_summary(TaskEvent.t()) :: String.t() | nil
  defp event_summary(%{type: :uploaded, data: d}),
    do: "#{d["content_type"]} · #{format_bytes(d["input_size"])}"

  defp event_summary(%{type: :ffmpeg_started, data: %{"argv" => argv}}),
    do: "ffmpeg " <> Enum.join(argv, " ")

  defp event_summary(%{type: :ffmpeg_finished, data: %{"timeout" => true}}), do: "timed out"

  defp event_summary(%{type: :ffmpeg_finished, data: %{"exit_code" => code}}),
    do: "exit code #{code}"

  defp event_summary(%{type: :s3_download_finished, data: %{"bytes" => b}}), do: format_bytes(b)

  defp event_summary(%{type: :s3_upload_finished, data: d}),
    do: "#{d["output_key"]} · #{format_bytes(d["output_size"])}"

  defp event_summary(%{type: type, data: %{"error" => error}})
       when type in [:attempt_failed, :failed], do: error

  defp event_summary(%{type: :retry_scheduled, data: %{"next_attempt" => n}}),
    do: "next attempt: #{n}"

  defp event_summary(%{type: :completed, data: %{"expires_at" => at}}),
    do: "result kept until #{at}"

  defp event_summary(%{type: type, data: %{"key" => key}})
       when type in [:input_deleted, :output_deleted], do: key

  defp event_summary(%{type: :enqueued, data: %{"job_id" => id}}), do: "job #{id}"
  defp event_summary(_event), do: nil
end
