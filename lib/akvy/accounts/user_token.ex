defmodule Akvy.Accounts.UserToken do
  @moduledoc """
  Session tokens. Stored so individual sessions can be expired.
  """
  use Akvy.Schema
  import Ecto.Query
  alias Akvy.Accounts.UserToken

  @rand_size 32
  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :user, Akvy.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @typedoc "Always `\"session\"`; older rows may hold the removed email-token contexts."
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

  @spec by_token_and_context_query(binary(), String.t()) :: Ecto.Query.t()
  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
