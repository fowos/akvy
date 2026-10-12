defmodule AkvyWeb do
  @moduledoc """
  Shared `use` definitions for the web layer: `use AkvyWeb, :controller`,
  `:html`, `:live_view`, `:live_component`, `:router`, `:channel`.
  """

  @doc "Top-level entries of `priv/static` served by `Plug.Static`."
  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  @spec router() :: Macro.t()
  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @spec channel() :: Macro.t()
  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  @spec controller() :: Macro.t()
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: AkvyWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @spec live_view() :: Macro.t()
  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  @spec live_component() :: Macro.t()
  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  @spec html() :: Macro.t()
  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  @spec html_helpers() :: Macro.t()
  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: AkvyWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import AkvyWeb.CoreComponents
      import AkvyWeb.AdminComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias AkvyWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  @spec verified_routes() :: Macro.t()
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AkvyWeb.Endpoint,
        router: AkvyWeb.Router,
        statics: AkvyWeb.static_paths()
    end
  end

  @doc "Injects the definitions for `which` (`:controller`, `:html`, ...)."
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
