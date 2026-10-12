defmodule AkvyWeb.ApiSpec do
  @moduledoc """
  OpenAPI 3 specification of the client API, served at `/api/openapi` and
  rendered with Swagger UI at `/api/docs`.
  """
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(AkvyWeb.Endpoint)],
      info: %Info{
        title: "Akvy",
        version: "1.0",
        description: """
        Self-hosted FFmpeg conversion service.

        1. `GET /api/v1/queues` — pick a queue.
        2. `POST /api/v1/queues/{queue_id}/tasks` — upload a file (multipart field `file`).
        3. `GET /api/v1/tasks/{id}/events` — follow progress via Server-Sent Events.
        4. `GET /api/v1/tasks/{id}/result` — download the result once `completed`.
           The result is deleted right after a successful download, or after the queue's TTL.

        Authenticate with `Authorization: Bearer <api key>`. SSE endpoints also accept
        `?api_key=` because browser `EventSource` cannot send headers.
        """
      },
      paths: Paths.from_router(AkvyWeb.Router),
      components: %Components{
        securitySchemes: %{"bearer" => %SecurityScheme{type: "http", scheme: "bearer"}}
      },
      security: [%{"bearer" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
