defmodule Akvy.ApiKeys.ApiKey do
  @moduledoc """
  API key used by client applications. Only a SHA-256 hash of the key is stored.
  """
  use Akvy.Schema
  import Ecto.Changeset

  schema "api_keys" do
    field :name, :string
    field :prefix, :string
    field :key_hash, :binary, redact: true
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: UUIDv7.t() | nil,
          name: String.t() | nil,
          prefix: String.t() | nil,
          key_hash: binary() | nil,
          last_used_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Casts and validates the user-editable `name`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t(t())
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
  end
end
