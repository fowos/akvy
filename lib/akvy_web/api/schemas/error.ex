defmodule AkvyWeb.Api.Schemas.Error do
  @moduledoc "OpenAPI schema of an API error response."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Error",
    type: :object,
    properties: %{
      errors: %Schema{
        type: :object,
        properties: %{detail: %Schema{type: :string}},
        additionalProperties: true
      }
    },
    required: [:errors]
  })
end
