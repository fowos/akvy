defmodule AkvyWeb.Api.Schemas.TaskList do
  @moduledoc "OpenAPI schema of a paginated task list response."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TaskList",
    type: :object,
    properties: %{
      data: %Schema{type: :array, items: AkvyWeb.Api.Schemas.Task},
      next_cursor: %Schema{
        type: :string,
        nullable: true,
        description: "Pass as `cursor` to fetch the next page"
      }
    },
    required: [:data]
  })
end
