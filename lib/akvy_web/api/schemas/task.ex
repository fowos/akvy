defmodule AkvyWeb.Api.Schemas.Task do
  @moduledoc "OpenAPI schema of a conversion task."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  @statuses ~w(uploaded processing retrying completed downloading failed downloaded expired cancelled)
  @ms %Schema{type: :integer, nullable: true}
  @time %Schema{type: :string, format: :"date-time", nullable: true}

  OpenApiSpex.schema(%{
    title: "Task",
    description: """
    Conversion task. Lifecycle: `uploaded` → `processing` (→ `retrying` → `processing`…) →
    `completed` → `downloaded` | `expired`; or `failed` / `cancelled`.
    """,
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      queue_id: %Schema{type: :string, format: :uuid},
      status: %Schema{type: :string, enum: @statuses},
      attempt: %Schema{type: :integer},
      original_filename: %Schema{type: :string, nullable: true},
      content_type: %Schema{type: :string, nullable: true},
      input_size: %Schema{type: :integer, nullable: true},
      output_size: %Schema{type: :integer, nullable: true},
      error: %Schema{type: :string, nullable: true},
      uploaded_at: @time,
      started_at: @time,
      finished_at: @time,
      downloaded_at: @time,
      expires_at: %Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "The result is deleted after this moment if not downloaded"
      },
      timings: %Schema{
        type: :object,
        description: "Durations in milliseconds of the last attempt",
        properties: %{
          upload_ms: @ms,
          queue_wait_ms: @ms,
          s3_download_ms: @ms,
          ffmpeg_ms: @ms,
          s3_upload_ms: @ms,
          processing_ms: @ms,
          total_ms: @ms
        }
      },
      links: %Schema{
        type: :object,
        properties: %{
          self: %Schema{type: :string},
          events: %Schema{type: :string, description: "SSE stream of this task"},
          result: %Schema{type: :string, description: "Download URL (available when completed)"}
        }
      }
    },
    required: [:id, :queue_id, :status]
  })
end
