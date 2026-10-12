defmodule Akvy.Repo.Migrations.CreateQueues do
  use Ecto.Migration

  def change do
    create table(:queues, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :ffmpeg_args, :text, null: false
      add :output_extension, :string, null: false
      add :output_content_type, :string, null: false, default: "application/octet-stream"
      add :max_file_size_bytes, :bigint, null: false
      add :allowed_content_types, {:array, :string}, null: false, default: []
      add :result_ttl_seconds, :integer, null: false
      add :max_attempts, :integer, null: false, default: 3
      add :timeout_seconds, :integer, null: false
      add :log_retention_days, :integer, null: false, default: 7
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:queues, [:name])
  end
end
