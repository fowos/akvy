defmodule AkvyWeb.Admin.QueueLive.Form do
  @moduledoc """
  Create/edit form for a queue (`/admin/queues/new`, `/admin/queues/:id/edit`) with a
  live FFmpeg command preview.
  """
  use AkvyWeb, :live_view

  alias Akvy.Queues
  alias Akvy.Queues.Queue

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  @spec apply_action(Phoenix.LiveView.Socket.t(), :new | :edit, map()) :: Phoenix.LiveView.Socket.t()
  defp apply_action(socket, :new, _params) do
    queue = %Queue{}

    socket
    |> assign(page_title: "New queue", queue: queue)
    |> assign_form(Queues.change_queue(queue))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    queue = Queues.get_queue!(id)

    socket
    |> assign(page_title: "Edit #{queue.name}", queue: queue)
    |> assign_form(Queues.change_queue(queue))
  end

  @impl true
  def handle_event("validate", %{"queue" => params}, socket) do
    changeset = Queues.change_queue(socket.assigns.queue, normalize(params))
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"queue" => params}, socket) do
    params = normalize(params)

    result =
      case socket.assigns.live_action do
        :new -> Queues.create_queue(params)
        :edit -> Queues.update_queue(socket.assigns.queue, params)
      end

    case result do
      {:ok, queue} ->
        {:noreply,
         socket
         |> put_flash(:info, "Queue saved")
         |> push_navigate(to: ~p"/admin/queues/#{queue}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("delete", _params, socket) do
    case Queues.delete_queue(socket.assigns.queue) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Queue deleted") |> push_navigate(to: ~p"/admin/queues")}

      {:error, changeset} ->
        message =
          changeset.errors |> Keyword.values() |> Enum.map_join(", ", &elem(&1, 0))

        {:noreply, put_flash(socket, :error, "Cannot delete: #{message}")}
    end
  end

  # Human-friendly form fields: size in MB, TTL in hours, content types as text.
  @spec normalize(map()) :: map()
  defp normalize(params) do
    params
    |> convert("max_file_size_mb", "max_file_size_bytes", &(&1 * 1024 * 1024))
    |> convert("result_ttl_hours", "result_ttl_seconds", &(&1 * 3600))
    |> Map.update("allowed_content_types", [], fn
      value when is_binary(value) -> String.split(value, [",", "\n", " "], trim: true)
      value -> value
    end)
  end

  @spec convert(map(), String.t(), String.t(), (float() -> number())) :: map()
  defp convert(params, from, to, fun) do
    case Float.parse(to_string(params[from] || "")) do
      {value, _} -> Map.put(params, to, round(fun.(value)))
      :error -> params
    end
  end

  @spec assign_form(Phoenix.LiveView.Socket.t(), Ecto.Changeset.t()) :: Phoenix.LiveView.Socket.t()
  defp assign_form(socket, changeset) do
    queue = Ecto.Changeset.apply_changes(changeset)

    socket
    |> assign(:form, to_form(changeset))
    |> assign(:size_mb, Float.round(queue.max_file_size_bytes / 1024 / 1024, 2))
    |> assign(:ttl_hours, Float.round(queue.result_ttl_seconds / 3600, 2))
    |> assign(:content_types, Enum.join(queue.allowed_content_types || [], ", "))
    |> assign(:preview, preview(queue.ffmpeg_args, queue.output_extension))
  end

  @spec preview(String.t() | nil, String.t() | nil) :: String.t() | {:error, String.t()} | nil
  defp preview(args, ext) when is_binary(args) do
    case Akvy.FFmpeg.build_argv(args, "/work/input", "/work/output.#{ext || "out"}") do
      {:ok, argv} -> "ffmpeg " <> Enum.join(argv, " ")
      {:error, message} -> {:error, message}
    end
  end

  defp preview(_, _), do: nil

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
      <.page_header title={@page_title} />

      <.form for={@form} id="queue-form" phx-change="validate" phx-submit="save">
        <div class="grid gap-6 lg:grid-cols-3">
          <div class="space-y-6 lg:col-span-2">
            <.card title="General">
              <div class="p-5 space-y-2">
                <.input field={@form[:name]} label="Name" placeholder="video-h264-720p" />
                <.input field={@form[:description]} type="textarea" label="Description" rows="2" />
                <.input field={@form[:enabled]} type="checkbox" label="Accept new tasks" />
              </div>
            </.card>

            <.card title="FFmpeg command">
              <div class="p-5 space-y-2">
                <.input
                  field={@form[:ffmpeg_args]}
                  type="textarea"
                  rows="3"
                  label="Arguments"
                  class="w-full textarea font-mono text-sm"
                  placeholder="-i {input} -c:v libx264 -preset veryfast -crf 23 -c:a aac {output}"
                />
                <p class="text-xs text-base-content/60">
                  Use <code class="rounded bg-base-200 px-1">{"{input}"}</code>
                  and <code class="rounded bg-base-200 px-1">{"{output}"}</code>
                  placeholders. Arguments are passed directly to ffmpeg, without a shell.
                </p>
                <div
                  :if={is_binary(@preview)}
                  id="command-preview"
                  class="mt-3 rounded-lg bg-neutral p-3 font-mono text-xs text-neutral-content break-all"
                >
                  $ {@preview}
                </div>
                <div class="grid gap-4 sm:grid-cols-2 pt-2">
                  <.input field={@form[:output_extension]} label="Output extension" placeholder="mp4" />
                  <.input
                    field={@form[:output_content_type]}
                    label="Output content type"
                    placeholder="video/mp4"
                  />
                </div>
              </div>
            </.card>
          </div>

          <div class="space-y-6">
            <.card title="Limits">
              <div class="p-5 space-y-2">
                <.input
                  name="queue[max_file_size_mb]"
                  id="queue_max_file_size_mb"
                  type="number"
                  step="any"
                  min="0"
                  label="Max upload size, MB"
                  value={@size_mb}
                  errors={field_errors(@form, :max_file_size_bytes)}
                />
                <.input
                  name="queue[allowed_content_types]"
                  id="queue_allowed_content_types"
                  label="Allowed content types"
                  placeholder="video/*, audio/mpeg (empty = any)"
                  value={@content_types}
                />
                <.input field={@form[:timeout_seconds]} type="number" label="FFmpeg timeout, s" />
                <.input field={@form[:max_attempts]} type="number" label="Max attempts" />
              </div>
            </.card>

            <.card title="Retention">
              <div class="p-5 space-y-2">
                <.input
                  name="queue[result_ttl_hours]"
                  id="queue_result_ttl_hours"
                  type="number"
                  step="any"
                  min="0"
                  label="Keep undownloaded result, hours"
                  value={@ttl_hours}
                  errors={field_errors(@form, :result_ttl_seconds)}
                />
                <.input field={@form[:log_retention_days]} type="number" label="Keep logs, days" />
              </div>
            </.card>

            <div class="flex items-center gap-3">
              <button
                id="save-queue"
                type="submit"
                phx-disable-with="Saving…"
                class="flex-1 rounded-lg bg-primary px-4 py-2.5 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110 active:scale-[.98]"
              >
                Save queue
              </button>
              <button
                :if={@live_action == :edit}
                id="delete-queue"
                type="button"
                phx-click="delete"
                data-confirm="Delete this queue?"
                class="rounded-lg border border-error/30 px-4 py-2.5 text-sm font-medium text-error transition hover:bg-error/10"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  @spec field_errors(Phoenix.HTML.Form.t(), atom()) :: [String.t()]
  defp field_errors(form, field) do
    if Phoenix.Component.used_input?(form[field]) or form.source.action do
      Enum.map(form[field].errors, &translate_error/1)
    else
      []
    end
  end
end
