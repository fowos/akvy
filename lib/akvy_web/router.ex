defmodule AkvyWeb.Router do
  @moduledoc "Routes for the landing page, client API, admin panel and authentication."
  use AkvyWeb, :router

  import AkvyWeb.UserAuth
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AkvyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api_spec do
    plug OpenApiSpex.Plug.PutApiSpec, module: AkvyWeb.ApiSpec
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug AkvyWeb.Plugs.ApiKeyAuth
  end

  # Binary downloads: any Accept header.
  pipeline :api_raw do
    plug AkvyWeb.Plugs.ApiKeyAuth
  end

  # Server-Sent Events: the key may be passed as ?api_key= for EventSource.
  pipeline :api_sse do
    plug AkvyWeb.Plugs.ApiKeyAuth, allow_query: true
  end

  scope "/", AkvyWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", AkvyWeb do
    get "/health", HealthController, :show
  end

  ## Client API

  scope "/api" do
    pipe_through :api_spec

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api" do
    pipe_through [:browser]

    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi", persist_authorization: true
  end

  scope "/api/v1", AkvyWeb.Api do
    pipe_through [:api_spec, :api]

    get "/queues", QueueController, :index
    post "/queues/:queue_id/tasks", TaskController, :create
    get "/tasks", TaskController, :index
    get "/tasks/:id", TaskController, :show
    delete "/tasks/:id", TaskController, :delete
  end

  scope "/api/v1", AkvyWeb.Api do
    pipe_through [:api_spec, :api_raw]

    get "/tasks/:id/result", TaskController, :result
  end

  scope "/api/v1", AkvyWeb.Api do
    pipe_through [:api_spec, :api_sse]

    get "/tasks/:id/events", EventController, :task
    get "/events", EventController, :index
  end

  ## Admin panel

  scope "/admin", AkvyWeb.Admin do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{AkvyWeb.UserAuth, :require_authenticated}] do
      live "/", DashboardLive, :index
      live "/queues", QueueLive.Index, :index
      live "/queues/new", QueueLive.Form, :new
      live "/queues/:id", QueueLive.Show, :show
      live "/queues/:id/edit", QueueLive.Form, :edit
      live "/tasks", TaskLive.Index, :index
      live "/tasks/:id", TaskLive.Show, :show
      live "/api-keys", ApiKeyLive.Index, :index
      live "/cluster", ClusterLive, :index
    end

    # Read-only download: does not change the task or delete the file.
    get "/tasks/:id/result", ResultController, :show
  end

  scope "/admin" do
    pipe_through [:browser, :require_authenticated_user]

    live_dashboard "/system", metrics: AkvyWeb.Telemetry
  end

  ## Authentication routes

  scope "/", AkvyWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user_settings,
      on_mount: [{AkvyWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", AkvyWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{AkvyWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
