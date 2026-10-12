defmodule Akvy.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    # Snapshot of the current state of every task (projection of task_events).
    create table(:tasks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :queue_id, references(:queues, on_delete: :restrict), null: false
      add :api_key_id, references(:api_keys, on_delete: :nilify_all)
      add :status, :string, null: false
      add :version, :integer, null: false, default: 0
      add :attempt, :integer, null: false, default: 0
      add :node, :string
      add :original_filename, :string
      add :content_type, :string
      add :input_key, :string
      add :input_size, :bigint
      add :output_key, :string
      add :output_size, :bigint
      add :error, :text
      add :exit_code, :integer

      add :uploaded_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :downloaded_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :input_deleted_at, :utc_datetime_usec
      add :output_deleted_at, :utc_datetime_usec

      add :upload_ms, :integer
      add :queue_wait_ms, :integer
      add :s3_download_ms, :integer
      add :ffmpeg_ms, :integer
      add :s3_upload_ms, :integer
      add :processing_ms, :integer
      add :total_ms, :integer

      timestamps()
    end

    create index(:tasks, [:status, :expires_at])
    create index(:tasks, [:queue_id, :inserted_at])
    create index(:tasks, [:api_key_id, :inserted_at])
    create index(:tasks, [:inserted_at])

    # Append-only history of everything that happened to a task.
    create table(:task_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :type, :string, null: false
      add :attempt, :integer, null: false, default: 0
      add :node, :string
      add :occurred_at, :utc_datetime_usec, null: false
      add :duration_ms, :integer
      add :data, :map, null: false, default: %{}
    end

    create unique_index(:task_events, [:task_id, :seq])
    create index(:task_events, [:type, :occurred_at])

    # Verbose logs (ffmpeg output, worker messages). Pruned periodically.
    create table(:task_logs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :attempt, :integer, null: false, default: 0
      add :line, :integer, null: false, default: 0
      add :source, :string, null: false
      add :level, :string, null: false, default: "info"
      add :message, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:task_logs, [:task_id, :attempt, :line])
    create index(:task_logs, [:inserted_at])
  end
end
