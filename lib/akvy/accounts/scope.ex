defmodule Akvy.Accounts.Scope do
  @moduledoc """
  Caller context passed to context functions: who is acting, used for
  authorization, query filtering and scoping PubSub topics.
  """

  alias Akvy.Accounts.User

  defstruct user: nil

  @type t :: %__MODULE__{user: User.t() | nil}

  @doc "Creates a scope for the given user; returns nil for nil."
  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil
end
