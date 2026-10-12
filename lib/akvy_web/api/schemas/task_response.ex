defmodule AkvyWeb.Api.Schemas.TaskResponse do
  @moduledoc "OpenAPI schema of a single-task response."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TaskResponse",
    type: :object,
    properties: %{data: AkvyWeb.Api.Schemas.Task},
    required: [:data]
  })
end
