defmodule Akvy.Accounts do
  @moduledoc """
  Users, password authentication, session tokens and account settings.
  """

  import Ecto.Query, warn: false
  alias Akvy.Repo

  alias Akvy.Accounts.{User, UserToken}

  @typedoc "Updated user and the tokens that were deleted (to disconnect their sessions)."
  @type user_and_expired_tokens :: {User.t(), [UserToken.t()]}

  ## Database getters

  @doc "Gets a user by email, or nil."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc "Gets a user by email if the password is valid, or nil."
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc "Gets a user by id. Raises `Ecto.NoResultsError` if not found."
  @spec get_user!(UUIDv7.t()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Creates a confirmed admin user with a password.
  Public registration is disabled; admins are created with `mix akvy.create_admin`.
  """
  @spec create_admin(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t(User.t())}
  def create_admin(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> User.password_changeset(attrs)
    |> User.confirm_changeset()
    |> Repo.insert()
  end

  ## Settings

  @doc "True when the user authenticated after `minutes` from now (default `-20`: 20 minutes ago)."
  @spec sudo_mode?(User.t() | nil, integer()) :: boolean()
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc "Changeset for changing the email; options as in `Akvy.Accounts.User.email_changeset/3`."
  @spec change_user_email(User.t(), map(), [User.email_option()]) ::
          Ecto.Changeset.t(User.t())
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc "Changes the email right away (the settings page requires sudo mode)."
  @spec update_user_email(User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t(User.t())}
  def update_user_email(user, attrs) do
    user
    |> User.email_changeset(attrs)
    |> Repo.update()
  end

  @doc "Changeset for changing the password; options as in `Akvy.Accounts.User.password_changeset/3`."
  @spec change_user_password(User.t(), map(), [User.password_option()]) ::
          Ecto.Changeset.t(User.t())
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc "Updates the password and deletes all tokens of the user; returns the deleted tokens."
  @spec update_user_password(User.t(), map()) ::
          {:ok, user_and_expired_tokens()} | {:error, Ecto.Changeset.t(User.t())}
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc "Generates and stores a session token; returns the raw token."
  @spec generate_user_session_token(User.t()) :: binary()
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc "Returns `{user, token_inserted_at}` for a valid session token, or nil."
  @spec get_user_by_session_token(binary()) :: {User.t(), DateTime.t()} | nil
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc "Deletes the given session token."
  @spec delete_user_session_token(binary()) :: :ok
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  @spec update_user_and_delete_all_tokens(Ecto.Changeset.t(User.t())) ::
          {:ok, user_and_expired_tokens()} | {:error, Ecto.Changeset.t(User.t())}
  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
