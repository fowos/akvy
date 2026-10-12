defmodule AkvyWeb.AdminComponents do
  @moduledoc """
  UI building blocks and formatting helpers for the admin panel.
  """
  use Phoenix.Component
  use Gettext, backend: AkvyWeb.Gettext

  import AkvyWeb.CoreComponents, only: [icon: 1]

  @stage_meta [
    queue_wait_ms: {"Queue wait", "bg-slate-400"},
    s3_download_ms: {"S3 download", "bg-sky-500"},
    ffmpeg_ms: {"FFmpeg", "bg-violet-500"},
    s3_upload_ms: {"S3 upload", "bg-emerald-500"},
    overhead_ms: {"Overhead", "bg-amber-400"}
  ]

  @periods [{"1h", 1}, {"24h", 24}, {"7d", 24 * 7}, {"30d", 24 * 30}]

  @typedoc "Period key as used in URLs, e.g. `\"24h\"`."
  @type period :: String.t()

  @typedoc "Processing stage key; also the timing field name on a task."
  @type stage ::
          :queue_wait_ms | :s3_download_ms | :ffmpeg_ms | :s3_upload_ms | :overhead_ms

  @typedoc "One coloured slice of a stage bar."
  @type segment :: %{
          key: stage(),
          label: String.t(),
          color: String.t(),
          ms: number(),
          pct: float()
        }

  @doc "Selectable periods as `{key, hours}` pairs."
  @spec periods() :: [{period(), pos_integer()}]
  def periods, do: @periods

  @doc "Returns the number of hours for a period key (default 24h)."
  @spec period_hours(period() | nil) :: pos_integer()
  def period_hours(key), do: Enum.find_value(@periods, 24, fn {k, h} -> k == key && h end)

  ## Layout pieces

  @doc "Page title row with optional subtitle and right-aligned actions."
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  @spec page_header(map()) :: Phoenix.LiveView.Rendered.t()
  def page_header(assigns) do
    ~H"""
    <div class="mb-8 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="text-2xl font-semibold tracking-tight">{@title}</h1>
        <p :if={@subtitle} class="mt-1 text-sm text-base-content/60">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc "Bordered panel with optional titled header and actions."
  attr :class, :any, default: nil
  attr :title, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    ~H"""
    <section
      class={["rounded-2xl border border-base-300 bg-base-100 shadow-xs", @class]}
      {@rest}
    >
      <div
        :if={@title || @actions != []}
        class="flex items-center justify-between gap-4 border-b border-base-300 px-5 py-3.5"
      >
        <h2 class="text-sm font-semibold">{@title}</h2>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "KPI tile: label, large value, icon and optional hint."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :icon, :string, required: true
  attr :tone, :string, default: "primary", values: ~w(primary info success error warning neutral)
  attr :id, :string, default: nil

  @spec stat(map()) :: Phoenix.LiveView.Rendered.t()
  def stat(assigns) do
    ~H"""
    <div
      id={@id}
      class="group rounded-2xl border border-base-300 bg-base-100 p-5 shadow-xs transition hover:-translate-y-0.5 hover:shadow-md"
    >
      <div class="flex items-center justify-between">
        <p class="text-sm text-base-content/60">{@label}</p>
        <span class={["size-9 rounded-xl grid place-items-center", tone_class(@tone)]}>
          <.icon name={@icon} class="size-5" />
        </span>
      </div>
      <p class="mt-3 text-3xl font-semibold tabular-nums tracking-tight">{@value}</p>
      <p :if={@hint} class="mt-1 text-xs text-base-content/50">{@hint}</p>
    </div>
    """
  end

  defp tone_class("primary"), do: "bg-primary/10 text-primary"
  defp tone_class("info"), do: "bg-info/10 text-info"
  defp tone_class("success"), do: "bg-success/10 text-success"
  defp tone_class("error"), do: "bg-error/10 text-error"
  defp tone_class("warning"), do: "bg-warning/10 text-warning"
  defp tone_class("neutral"), do: "bg-base-200 text-base-content/70"

  @doc "Coloured pill for a task status; pulses while in progress."
  attr :status, :any, required: true

  @spec status_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium whitespace-nowrap",
      status_class(@status)
    ]}>
      <span class={[
        "size-1.5 rounded-full bg-current",
        to_string(@status) in ~w(processing downloading) && "animate-pulse"
      ]} />
      {@status}
    </span>
    """
  end

  defp status_class(status) do
    case to_string(status) do
      "uploaded" -> "bg-base-200 text-base-content/70"
      "processing" -> "bg-info/10 text-info"
      "retrying" -> "bg-warning/10 text-warning"
      "completed" -> "bg-success/10 text-success"
      "downloading" -> "bg-info/10 text-info"
      "downloaded" -> "bg-primary/10 text-primary"
      "failed" -> "bg-error/10 text-error"
      "expired" -> "bg-base-300 text-base-content/60"
      "cancelled" -> "bg-base-300 text-base-content/60"
      _ -> "bg-base-200 text-base-content/70"
    end
  end

  @doc "Segmented period switch (1h/24h/7d/30d) that patches to `path.(key)`."
  attr :current, :string, required: true
  attr :path, :any, required: true, doc: "fn period -> path"

  @spec period_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def period_tabs(assigns) do
    assigns = assign(assigns, :periods, @periods)

    ~H"""
    <div id="period-tabs" class="inline-flex rounded-lg border border-base-300 bg-base-100 p-0.5">
      <.link
        :for={{key, _} <- @periods}
        patch={@path.(key)}
        class={[
          "rounded-md px-3 py-1 text-sm font-medium transition",
          if(@current == key,
            do: "bg-primary text-primary-content shadow-sm",
            else: "text-base-content/60 hover:text-base-content"
          )
        ]}
      >
        {key}
      </.link>
    </div>
    """
  end

  ## Timing visualisation

  @doc """
  Splits processing time into stages. Accepts any map with the stage keys
  (a task or aggregated averages). Returns non-empty segments and the total in ms.
  """
  @spec stage_segments(map()) :: {[segment()], number()}
  def stage_segments(timings) do
    get = fn key -> (Map.get(timings, key) || 0) |> max(0) end

    known = get.(:s3_download_ms) + get.(:ffmpeg_ms) + get.(:s3_upload_ms)
    processing = get.(:processing_ms)
    overhead = if processing > known, do: processing - known, else: 0

    values = %{
      queue_wait_ms: get.(:queue_wait_ms),
      s3_download_ms: get.(:s3_download_ms),
      ffmpeg_ms: get.(:ffmpeg_ms),
      s3_upload_ms: get.(:s3_upload_ms),
      overhead_ms: overhead
    }

    total = values |> Map.values() |> Enum.sum()

    segments =
      for {key, {label, color}} <- @stage_meta, values[key] > 0 do
        %{key: key, label: label, color: color, ms: values[key], pct: values[key] * 100 / total}
      end

    {segments, total}
  end

  @doc "Stacked horizontal bar with legend for per-stage processing time."
  attr :timings, :map, required: true
  attr :id, :string, required: true

  @spec stage_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def stage_bar(assigns) do
    {segments, total} = stage_segments(assigns.timings)
    assigns = assign(assigns, segments: segments, total: total)

    ~H"""
    <div id={@id}>
      <%= if @total == 0 do %>
        <p class="text-sm text-base-content/50">No timing data yet.</p>
      <% else %>
        <div class="flex h-3 w-full overflow-hidden rounded-full bg-base-200">
          <div
            :for={s <- @segments}
            class={[
              s.color,
              "h-full transition-all duration-500 first:rounded-l-full last:rounded-r-full"
            ]}
            style={"width: #{Float.round(s.pct, 2)}%"}
            title={"#{s.label}: #{format_ms(s.ms)}"}
          />
        </div>
        <div class="mt-3 flex flex-wrap gap-x-5 gap-y-1.5 text-xs">
          <div :for={s <- @segments} class="flex items-center gap-1.5">
            <span class={["size-2.5 rounded-sm", s.color]} />
            <span class="text-base-content/60">{s.label}</span>
            <span class="font-medium tabular-nums">{format_ms(s.ms)}</span>
            <span class="text-base-content/40 tabular-nums">{round(s.pct)}%</span>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @doc "Stacked column chart of succeeded/failed counts per time bucket."
  attr :rows, :list,
    required: true,
    doc: "maps with `:bucket` (DateTime), `:succeeded` and `:failed` counts"

  attr :id, :string, required: true
  attr :class, :any, default: nil, doc: "extra classes; the bars fill the available height"

  @spec throughput_chart(map()) :: Phoenix.LiveView.Rendered.t()
  def throughput_chart(assigns) do
    max = assigns.rows |> Enum.map(&(&1.succeeded + &1.failed)) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, max: max(max, 1))

    ~H"""
    <div id={@id} class={["flex flex-col", @class]}>
      <div class="flex min-h-40 flex-1 items-end gap-[2px]">
        <div
          :for={row <- @rows}
          class="group relative flex h-full flex-1 flex-col justify-end"
          title={"#{format_bucket(row.bucket)} — ok: #{row.succeeded}, failed: #{row.failed}"}
        >
          <div
            class="w-full rounded-t-[3px] bg-error/70 transition-all duration-500"
            style={"height: #{row.failed * 100 / @max}%"}
          />
          <div
            class="w-full bg-primary/70 transition-all duration-500 group-hover:bg-primary"
            style={"height: #{row.succeeded * 100 / @max}%"}
          />
        </div>
      </div>
      <div class="mt-2 flex justify-between text-xs text-base-content/40 tabular-nums">
        <span>{@rows |> List.first() |> then(&(&1 && format_bucket(&1.bucket)))}</span>
        <span>peak {@max}</span>
        <span>{@rows |> List.last() |> then(&(&1 && format_bucket(&1.bucket)))}</span>
      </div>
    </div>
    """
  end

  @doc "Centered placeholder for empty lists."
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col items-center justify-center px-6 py-14 text-center">
      <span class="size-12 rounded-2xl bg-base-200 grid place-items-center text-base-content/40">
        <.icon name={@icon} class="size-6" />
      </span>
      <p class="mt-4 font-medium">{@title}</p>
      <div class="mt-1 text-sm text-base-content/60">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  ## Formatting

  @doc "Human label for a stage key; falls back to the key itself."
  @spec stage_label(atom()) :: String.t()
  def stage_label(key), do: @stage_meta |> Keyword.get(key, {to_string(key), nil}) |> elem(0)

  @doc "Formats a duration in milliseconds, e.g. `\"850 ms\"`, `\"1.2 s\"`, `\"3 m 5 s\"`."
  @spec format_ms(number() | nil) :: String.t()
  def format_ms(nil), do: "—"

  def format_ms(ms) when is_float(ms), do: format_ms(round(ms))

  def format_ms(ms) when ms < 1_000, do: "#{ms} ms"
  def format_ms(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)} s"

  def format_ms(ms) when ms < 3_600_000 do
    "#{div(ms, 60_000)} m #{rem(div(ms, 1_000), 60)} s"
  end

  def format_ms(ms), do: "#{div(ms, 3_600_000)} h #{rem(div(ms, 60_000), 60)} m"

  @doc "Formats a byte count with a binary unit (B, KB, MB, GB)."
  @spec format_bytes(non_neg_integer() | nil) :: String.t()
  def format_bytes(nil), do: "—"
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"

  def format_bytes(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1024 ** 2, 1)} MB"

  def format_bytes(bytes), do: "#{Float.round(bytes / 1024 ** 3, 2)} GB"

  @doc "Formats as `YYYY-MM-DD HH:MM:SS`."
  @spec format_dt(DateTime.t() | nil) :: String.t()
  def format_dt(nil), do: "—"
  def format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  @doc "Formats as `HH:MM:SS.mmm`."
  @spec format_time(DateTime.t() | nil) :: String.t()
  def format_time(nil), do: "—"
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S.") <> pad_ms(dt)

  defp pad_ms(%DateTime{microsecond: {us, _}}),
    do: us |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0")

  @doc "Formats relative to now, e.g. `\"5m ago\"`, `\"in 2h\"`, `\"just now\"`."
  @spec format_relative(DateTime.t() | nil) :: String.t()
  def format_relative(nil), do: "—"

  def format_relative(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 0 -> "in " <> human_seconds(-diff)
      diff < 5 -> "just now"
      true -> human_seconds(diff) <> " ago"
    end
  end

  defp human_seconds(s) when s < 60, do: "#{s}s"
  defp human_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp human_seconds(s) when s < 86_400, do: "#{div(s, 3600)}h"
  defp human_seconds(s), do: "#{div(s, 86_400)}d"

  @doc "Formats `part / total` as a percentage with one decimal."
  @spec format_percent(number(), number()) :: String.t()
  def format_percent(_part, 0), do: "—"
  def format_percent(part, total), do: "#{Float.round(part * 100 / total, 1)}%"

  defp format_bucket(%DateTime{} = dt), do: Calendar.strftime(dt, "%d.%m %H:%M")
  defp format_bucket(_), do: ""
end
