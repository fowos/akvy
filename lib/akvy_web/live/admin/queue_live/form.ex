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

  @spec apply_action(Phoenix.LiveView.Socket.t(), :new | :edit, map()) ::
          Phoenix.LiveView.Socket.t()
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

  @spec assign_form(Phoenix.LiveView.Socket.t(), Ecto.Changeset.t()) ::
          Phoenix.LiveView.Socket.t()
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

  @spec field_errors(Phoenix.HTML.Form.t(), atom()) :: [String.t()]
  defp field_errors(form, field) do
    if Phoenix.Component.used_input?(form[field]) or form.source.action do
      Enum.map(form[field].errors, &translate_error/1)
    else
      []
    end
  end
end
