defmodule Akvy.ApiKeys do
  @moduledoc """
  Issuing, authenticating and revoking API keys for client applications.
  """
  import Ecto.Query

  alias Akvy.Repo
  alias Akvy.ApiKeys.ApiKey

  @key_prefix "akvy_"
  # Throttle `last_used_at` writes so hot keys don't update the row on every request.
  @touch_interval_seconds 60

  @doc "Lists all API keys, newest first, including revoked ones."
  @spec list_api_keys() :: [ApiKey.t()]
  def list_api_keys do
    Repo.all(from k in ApiKey, order_by: [desc: k.id])
  end

  @doc "Gets an API key by id. Raises `Ecto.NoResultsError` if not found."
  @spec get_api_key!(UUIDv7.t()) :: ApiKey.t()
  def get_api_key!(id), do: Repo.get!(ApiKey, id)

  @doc "Returns a changeset for tracking API key form changes."
  @spec change_api_key(ApiKey.t(), map()) :: Ecto.Changeset.t(ApiKey.t())
  def change_api_key(%ApiKey{} = api_key, attrs \\ %{}), do: ApiKey.changeset(api_key, attrs)

  @doc """
  Creates an API key. Returns `{:ok, api_key, raw_key}`; the raw key is never stored
  and must be shown to the user exactly once.
  """
  @spec create_api_key(map()) ::
          {:ok, ApiKey.t(), String.t()} | {:error, Ecto.Changeset.t(ApiKey.t())}
  def create_api_key(attrs) do
    raw_key = @key_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    changeset =
      %ApiKey{}
      |> ApiKey.changeset(attrs)
      |> Ecto.Changeset.put_change(:key_hash, hash(raw_key))
      |> Ecto.Changeset.put_change(:prefix, String.slice(raw_key, 0, 12))

    with {:ok, api_key} <- Repo.insert(changeset) do
      {:ok, api_key, raw_key}
    end
  end

  @doc """
  Returns the non-revoked API key matching the raw key, or nil for anything else.
  Updates `last_used_at` at most once per #{@touch_interval_seconds} seconds.
  """
  @spec authenticate(term()) :: ApiKey.t() | nil
  def authenticate(raw_key) when is_binary(raw_key) do
    query = from k in ApiKey, where: k.key_hash == ^hash(raw_key) and is_nil(k.revoked_at)

    case Repo.one(query) do
      nil -> nil
      api_key -> touch(api_key)
    end
  end

  def authenticate(_), do: nil

  @doc "Revokes an API key by setting `revoked_at`."
  @spec revoke_api_key(ApiKey.t()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t(ApiKey.t())}
  def revoke_api_key(%ApiKey{} = api_key) do
    api_key
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
    |> Repo.update()
  end

  @spec touch(ApiKey.t()) :: ApiKey.t()
  defp touch(%ApiKey{last_used_at: last} = api_key) do
    now = DateTime.utc_now()

    if is_nil(last) or DateTime.diff(now, last) >= @touch_interval_seconds do
      Repo.update_all(from(k in ApiKey, where: k.id == ^api_key.id), set: [last_used_at: now])
      %{api_key | last_used_at: now}
    else
      api_key
    end
  end

  @spec hash(String.t()) :: binary()
  defp hash(raw_key), do: :crypto.hash(:sha256, raw_key)
end
