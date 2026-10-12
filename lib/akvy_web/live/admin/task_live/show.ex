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
