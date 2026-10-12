defmodule Akvy.Repo.Migrations.CreateInstanceHeartbeats do
  use Ecto.Migration

  def change do
    # One row per instance boot. Jobs and downloads owned by a boot without a fresh
    # heartbeat are rescued (see Akvy.Workers.RescueOrphans).
    create table(:instance_heartbeats, primary_key: false) do
      add :boot_id, :uuid, primary_key: true
      add :instance, :string, null: false
      # Oban producer of the `convert` queue; matches `oban_jobs.attempted_by[2]`.
      add :producer_uuid, :uuid
      add :started_at, :utc_datetime_usec, null: false
      add :seen_at, :utc_datetime_usec, null: false
    end

    create index(:instance_heartbeats, [:producer_uuid])
    create index(:instance_heartbeats, [:instance, :seen_at])
  end
end
