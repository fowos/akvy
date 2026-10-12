defmodule Akvy.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :prefix, :string, null: false
      add :key_hash, :binary, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:api_keys, [:key_hash])
  end
end
