defmodule AkvyWeb.UserLive.Login do
  @moduledoc """
  Email/password log-in page (`/users/log-in`). Submits via `phx-trigger-action` to
  `AkvyWeb.UserSessionController` so the session cookie is set over HTTP.
  """
  use AkvyWeb, :live_view

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
