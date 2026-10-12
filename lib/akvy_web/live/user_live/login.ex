defmodule AkvyWeb.UserLive.Login do
  @moduledoc """
  Email/password log-in page (`/users/log-in`). Submits via `phx-trigger-action` to
  `AkvyWeb.UserSessionController` so the session cookie is set over HTTP.
  """
  use AkvyWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} centered>
      <div class="space-y-6">
        <div>
          <h1 class="text-xl font-semibold tracking-tight">
            {if @current_scope, do: "Confirm it's you", else: "Sign in"}
          </h1>

          <p class="mt-1 text-sm text-base-content/60">
            <%= if @current_scope do %>
              You need to reauthenticate to perform sensitive actions.
            <% else %>
              Admin panel access. Accounts are created with <code class="text-xs">mix akvy.create_admin</code>.
            <% end %>
          </p>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
          class="space-y-1"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
            required
          /> <.input field={@form[:remember_me]} type="checkbox" label="Keep me signed in" />
          <button
            id="login-submit"
            type="submit"
            phx-disable-with="Signing in…"
            class="mt-3 w-full rounded-lg bg-primary px-4 py-2.5 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110 active:scale-[.98]"
          >
            Sign in <span aria-hidden="true">→</span>
          </button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
