defmodule Akvy.Accounts.UserToken do
  @moduledoc """
  User tokens: signed session tokens and hashed email tokens
  (magic link login, email change).
  """
  use Akvy.Schema
  import Ecto.Query
  alias Akvy.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7
  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :user, Akvy.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @typedoc "`\"session\"`, `\"login\"` or `\"change:<old email>\"`."
  @type context :: String.t()

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: UUIDv7.t() | nil,
          token: binary() | nil,
          context: context() | nil,
          sent_to: String.t() | nil,
          authenticated_at: DateTime.t() | nil,
          user_id: UUIDv7.t() | nil,
          user: Akvy.Accounts.User.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @doc """
  Builds a raw session token and its unsaved `UserToken`.

  Session tokens live in a signed cookie, so they are stored unhashed. Persisting
  them lets individual sessions be expired, which plain Phoenix session cookies
  do not allow.
  """
  @spec build_session_token(Akvy.Accounts.User.t()) :: {binary(), t()}
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now(:second)
    {token, %UserToken{token: token, context: "session", user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks if the session token is valid and returns its lookup query.

  The query returns `{user, token_inserted_at}` (with `user.authenticated_at` set)
  when the token matches and has not expired (after #{@session_validity_in_days} days).
  """
  @spec verify_session_token_query(binary()) :: {:ok, Ecto.Query.t()}
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds a token to be delivered to the user's email.

  Returns the URL-safe encoded raw token (to send) and an unsaved `UserToken` holding
  only its SHA-256 hash. Tokens become invalid once the user's email changes.
  """
  @spec build_email_token(Akvy.Accounts.User.t(), context()) :: {String.t(), t()}
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  @spec build_hashed_token(Akvy.Accounts.User.t(), context(), String.t()) :: {String.t(), t()}
  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the magic link token is valid and returns its lookup query.

  The query returns `{user, token}` when the hashed token matches, has context
  `"login"`, has not expired and was sent to the user's current email.
  Returns `:error` if the token is not valid Base64.
  """
  @spec verify_magic_link_token_query(String.t()) :: {:ok, Ecto.Query.t()} | :error
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "login"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if an email change token is valid and returns its lookup query.

  The query returns the matching `UserToken`, if its hash matches and it has not
  expired (after #{@change_email_validity_in_days} days). `context` must start with
  `"change:"`. Returns `:error` if the token is not valid Base64.
  """
  @spec verify_change_email_token_query(String.t(), context()) ::
          {:ok, Ecto.Query.t()} | :error
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
