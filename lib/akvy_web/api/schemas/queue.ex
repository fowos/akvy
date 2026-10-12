defmodule AkvyWeb.Api.Schemas.Queue do
  @moduledoc "OpenAPI schema of a conversion queue."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Queue",
    description: "Conversion queue. Pass its `id` when uploading a file.",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string},
      description: %Schema{type: :string, nullable: true},
      output_extension: %Schema{type: :string, example: "mp4"},
      output_content_type: %Schema{type: :string, example: "video/mp4"},
      max_file_size_bytes: %Schema{type: :integer, description: "Maximum upload size"},
      allowed_content_types: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "Accepted MIME types (`video/*` wildcards allowed). Empty means any."
      },
      result_ttl_seconds: %Schema{
        type: :integer,
        description: "How long the result is kept if it is not downloaded"
      }
    },
    required: [:id, :name, :output_extension, :max_file_size_bytes]
  })
end
