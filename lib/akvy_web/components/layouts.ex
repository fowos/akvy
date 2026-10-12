defmodule AkvyWeb.Layouts do
  @moduledoc """
  Root and app layouts: admin sidebar shell, centered auth shell, flash group
  and theme switch.
  """
  use AkvyWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout: a sidebar admin shell for signed-in users and a
  centered card layout for the authentication pages.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} active={:tasks}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom, default: nil, doc: "the active navigation item"
  attr :centered, :boolean, default: false, doc: "use the centered authentication layout"

  slot :inner_block, required: true

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    if assigns.centered or is_nil(assigns.current_scope),
      do: auth_shell(assigns),
      else: admin_shell(assigns)
  end

  defp auth_shell(assigns) do
    ~H"""
    <main class="min-h-screen flex flex-col items-center justify-center px-4 py-16">
      <.brand class="mb-8" />
      <div class="w-full max-w-sm rounded-2xl border border-base-300 bg-base-100 p-8 shadow-sm">
        {render_slot(@inner_block)}
      </div>

      <div class="mt-6"><.theme_toggle /></div>
    </main>
    <.flash_group flash={@flash} />
    """
  end

  defp admin_shell(assigns) do
    ~H"""
    <div class="min-h-screen lg:flex">
      <aside class="max-lg:sticky max-lg:top-0 max-lg:z-30 lg:fixed lg:inset-y-0 lg:w-60 flex flex-col border-b lg:border-b-0 lg:border-r border-base-300 bg-base-100">
        <div class="flex items-center justify-between px-5 h-16 shrink-0">
          <.brand />
          <button
            id="admin-menu-toggle"
            type="button"
            class="lg:hidden group btn btn-ghost btn-sm btn-square"
            aria-label="Menu"
            aria-controls="admin-menu"
            aria-expanded="false"
            phx-click={toggle_admin_menu()}
          >
            <.icon name="hero-bars-3" class="size-6 group-aria-expanded:hidden" />
            <.icon name="hero-x-mark" class="size-6 hidden group-aria-expanded:block" />
          </button>
        </div>

        <div
          id="admin-menu"
          class="max-lg:hidden flex flex-col lg:flex-1 lg:min-h-0 max-lg:max-h-[calc(100dvh-4rem)] max-lg:overflow-y-auto max-lg:border-t border-base-300"
        >
          <nav class="flex flex-col gap-1 px-3 py-3 lg:py-0 lg:flex-1 lg:overflow-y-auto">
            <.nav_link
              navigate={~p"/admin"}
              icon="hero-chart-bar-square"
              active={@active == :dashboard}
            >
              Dashboard
            </.nav_link>

            <.nav_link navigate={~p"/admin/tasks"} icon="hero-film" active={@active == :tasks}>
              Tasks
            </.nav_link>

            <.nav_link
              navigate={~p"/admin/queues"}
              icon="hero-queue-list"
              active={@active == :queues}
            >
              Queues
            </.nav_link>

            <.nav_link navigate={~p"/admin/api-keys"} icon="hero-key" active={@active == :api_keys}>
              API keys
            </.nav_link>

            <.nav_link
              navigate={~p"/admin/cluster"}
              icon="hero-server-stack"
              active={@active == :cluster}
            >
              Cluster
            </.nav_link>

            <div class="my-3 border-t border-base-300"></div>
            <.nav_link href={~p"/api/docs"} icon="hero-book-open" target="_blank">API docs</.nav_link>
            <.nav_link href={~p"/admin/system"} icon="hero-cpu-chip">System</.nav_link>
          </nav>

          <div class="border-t border-base-300 p-4 space-y-3">
            <div class="flex items-center gap-3 min-w-0">
              <div class="size-8 shrink-0 rounded-full bg-primary/15 text-primary grid place-items-center text-sm font-semibold uppercase">
                {String.first(@current_scope.user.email)}
              </div>

              <div class="min-w-0">
                <p class="truncate text-sm font-medium">{@current_scope.user.email}</p>

                <div class="flex gap-3 text-xs text-base-content/60">
                  <.link navigate={~p"/users/settings"} class="hover:text-base-content transition">
                    Settings
                  </.link>

                  <.link
                    href={~p"/users/log-out"}
                    method="delete"
                    class="hover:text-base-content transition"
                  >
                    Log out
                  </.link>
                </div>
              </div>
            </div>

            <div class="flex items-center justify-between">
              <span class="text-xs text-base-content/50">Theme</span> <.theme_toggle />
            </div>
          </div>
        </div>
      </aside>

      <main class="flex-1 lg:pl-60">
        <div class="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-10">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  # Below `lg` the sidebar collapses into a dropdown under the top bar.
  defp toggle_admin_menu do
    JS.toggle_class("max-lg:hidden", to: "#admin-menu")
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#admin-menu-toggle")
  end

  attr :class, :any, default: nil

  defp brand(assigns) do
    ~H"""
    <.link navigate={~p"/admin"} class={["group flex items-center gap-2.5", @class]}>
      <span class="size-8 rounded-lg bg-gradient-to-br from-primary to-accent grid place-items-center text-primary-content shadow-sm transition group-hover:scale-105">
        <.icon name="hero-play-solid" class="size-4" />
      </span>
      <span class="text-lg font-semibold tracking-tight">Akvy</span>
    </.link>
    """
  end

  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :rest, :global, include: ~w(navigate href target)
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      class={[
        "flex shrink-0 items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
        if(@active,
          do: "bg-primary/10 text-primary",
          else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
        )
      ]}
      {@rest}
    >
      <.icon name={@icon} class="size-5" /> {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Segmented System / Light / Dark theme switch.

  The active segment is derived from the attributes that the script in
  root.html.heex sets on `<html>` (`data-theme`, `data-theme-source`), so it is
  correct before LiveView connects and needs no server state.
  """
  attr :class, :any, default: nil

  @spec theme_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_toggle(assigns) do
    ~H"""
    <div
      role="radiogroup"
      aria-label="Theme"
      class={[
        "inline-flex items-center gap-0.5 rounded-lg border border-base-300 bg-base-200 p-0.5",
        @class
      ]}
    >
      <.theme_option
        theme="system"
        label="System"
        icon="hero-computer-desktop-micro"
        active="[[data-theme-source=system]_&]:bg-base-100 [[data-theme-source=system]_&]:text-base-content [[data-theme-source=system]_&]:shadow-sm"
      />
      <.theme_option
        theme="light"
        label="Light"
        icon="hero-sun-micro"
        active="[[data-theme-source=user][data-theme=light]_&]:bg-base-100 [[data-theme-source=user][data-theme=light]_&]:text-base-content [[data-theme-source=user][data-theme=light]_&]:shadow-sm"
      />
      <.theme_option
        theme="dark"
        label="Dark"
        icon="hero-moon-micro"
        active="[[data-theme-source=user][data-theme=dark]_&]:bg-base-100 [[data-theme-source=user][data-theme=dark]_&]:text-base-content [[data-theme-source=user][data-theme=dark]_&]:shadow-sm"
      />
    </div>
    """
  end

  attr :theme, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active, :string, required: true

  defp theme_option(assigns) do
    ~H"""
    <button
      type="button"
      title={@label}
      aria-label={@label}
      phx-click={JS.dispatch("phx:set-theme")}
      data-phx-theme={@theme}
      class={[
        "grid size-7 cursor-pointer place-items-center rounded-md text-base-content/50 transition",
        "hover:text-base-content",
        @active
      ]}
    >
      <.icon name={@icon} class="size-4" />
    </button>
    """
  end
end
