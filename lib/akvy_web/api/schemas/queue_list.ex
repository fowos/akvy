defmodule AkvyWeb.Api.Schemas.QueueList do
  @moduledoc "OpenAPI schema of the queue list response."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "QueueList",
    type: :object,
    properties: %{data: %Schema{type: :array, items: AkvyWeb.Api.Schemas.Queue}},
    required: [:data]
  })
end
