defmodule AkvyWeb.Api.QueueController do
  @moduledoc "Client API: conversion queues."
  use AkvyWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Akvy.Queues
  alias AkvyWeb.Api.Schemas

  tags ["Queues"]

  operation :index,
    summary: "List queues",
    description: "Enabled conversion queues available to the client.",
    responses: [
      ok: {"Queues", "application/json", Schemas.QueueList},
      unauthorized: {"Missing or invalid API key", "application/json", Schemas.Error}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    render(conn, :index, queues: Queues.list_enabled_queues())
  end
end
