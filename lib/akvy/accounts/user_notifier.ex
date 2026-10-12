defmodule Akvy.Accounts.UserNotifier do
  @moduledoc "Plain-text account emails: magic link login, confirmation and email change."
  import Swoosh.Email

  alias Akvy.Mailer
  alias Akvy.Accounts.User

  @type delivery :: {:ok, Swoosh.Email.t()} | {:error, term()}

  # Delivers the email using the application mailer.
  @spec deliver(String.t(), String.t(), String.t()) :: delivery()
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Akvy", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc "Delivers the email change confirmation link."
  @spec deliver_update_email_instructions(User.t(), String.t()) :: delivery()
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc "Delivers a magic login link; unconfirmed users get confirmation wording."
  @spec deliver_login_instructions(User.t(), String.t()) :: delivery()
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
