defmodule Akvy.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Akvy.Accounts` context.
  """

  import Ecto.Query

  alias Akvy.Accounts
  alias Akvy.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  # A confirmed user without a password; use `set_password/1` when a test needs one.
  def user_fixture(attrs \\ %{}) do
    %Accounts.User{}
    |> Accounts.User.email_changeset(valid_user_attributes(attrs))
    |> Accounts.User.confirm_changeset()
    |> Akvy.Repo.insert!()
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Akvy.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Akvy.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
