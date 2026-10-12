defmodule AkvyWeb.Api.Schemas.TaskEvent do
  @moduledoc "OpenAPI schema of an SSE task event payload."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TaskEvent",
    description: """
    Payload of an SSE message (`event: task`, `id: <seq>`). The first message of a
    per-task stream is a snapshot (`event` = `snapshot`).
    """,
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid, description: "Task id"},
      queue_id: %Schema{type: :string, format: :uuid},
      status: %Schema{type: :string},
      event: %Schema{
        type: :string,
        example: "completed",
        description:
          "snapshot, uploaded, enqueued, attempt_started, s3_download_started, s3_download_finished, " <>
            "ffmpeg_started, ffmpeg_finished, s3_upload_started, s3_upload_finished, attempt_failed, " <>
            "retry_scheduled, completed, failed, input_deleted, download_started, download_aborted, " <>
            "downloaded, output_deleted, expired, cancelled"
      },
      seq: %Schema{type: :integer, description: "Monotonic per-task sequence number"},
      attempt: %Schema{type: :integer},
      occurred_at: %Schema{type: :string, format: :"date-time"},
      duration_ms: %Schema{type: :integer, nullable: true},
      error: %Schema{type: :string, nullable: true},
      output_size: %Schema{type: :integer, nullable: true},
      expires_at: %Schema{type: :string, format: :"date-time", nullable: true}
    },
    example: %{
      "id" => "0199d6a2-6f1e-7c3a-9b1e-3f6c2a1d4e5f",
      "queue_id" => "0199d6a0-1111-7aaa-8bbb-123456789abc",
      "status" => "completed",
      "event" => "completed",
      "seq" => 14,
      "attempt" => 1,
      "occurred_at" => "2026-10-12T10:00:30.000000Z",
      "duration_ms" => nil,
      "error" => nil,
      "output_size" => 1_048_576,
      "expires_at" => "2026-10-13T10:00:30.000000Z"
    }
  })
end
