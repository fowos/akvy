defmodule Akvy.Accounts do
  @moduledoc """
  Users, password and magic link authentication, session tokens and email changes.
  """

  import Ecto.Query, warn: false
  alias Akvy.Repo

  alias Akvy.Accounts.{User, UserToken, UserNotifier}

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

  @doc "Registers a user with an email only (no password)."
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t(User.t())}
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

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

  @doc "Applies an email change confirmed by `token` and deletes the change tokens."
  @spec update_user_email(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, :transaction_aborted}
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
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

  @doc "Gets the user with the given magic link token, or nil."
  @spec get_user_by_magic_link_token(String.t()) :: User.t() | nil
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link and deletes the link.

  An unconfirmed user is confirmed and all their tokens are deleted. Raises for an
  unconfirmed user with a password (session fixation protection).
  """
  @spec login_user_by_magic_link(String.t()) ::
          {:ok, user_and_expired_tokens()}
          | {:error, Ecto.Changeset.t(User.t()) | :not_found}
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Stores an email change token and emails the link built by `update_email_url_fun`."
  @spec deliver_user_update_email_instructions(
          User.t(),
          String.t(),
          (String.t() -> String.t())
        ) :: UserNotifier.delivery()
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc "Stores a login token and emails the magic link built by `magic_link_url_fun`."
  @spec deliver_login_instructions(User.t(), (String.t() -> String.t())) ::
          UserNotifier.delivery()
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
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
