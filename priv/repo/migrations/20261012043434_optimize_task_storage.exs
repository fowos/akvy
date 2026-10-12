defmodule Akvy.Repo.Migrations.OptimizeTaskStorage do
  use Ecto.Migration

  # Integer codes of the Ecto.Enum fields. They must match the schemas and never change.
  @event_types [
    uploaded: 1,
    enqueued: 2,
    attempt_started: 3,
    s3_download_started: 4,
    s3_download_finished: 5,
    ffmpeg_started: 6,
    ffmpeg_finished: 7,
    s3_upload_started: 8,
    s3_upload_finished: 9,
    attempt_failed: 10,
    retry_scheduled: 11,
    completed: 12,
    failed: 13,
    input_deleted: 14,
    download_started: 15,
    download_aborted: 16,
    downloaded: 17,
    output_deleted: 18,
    expired: 19,
    cancelled: 20
  ]

  @statuses [
    uploaded: 1,
    processing: 2,
    retrying: 3,
    completed: 4,
    downloading: 5,
    failed: 6,
    downloaded: 7,
    expired: 8,
    cancelled: 9
  ]

  @log_sources [ffmpeg: 1, worker: 2]
  @log_levels [debug: 1, info: 2, warning: 3, error: 4]

  def up do
    # Conversion job of the task, so lookups no longer scan `oban_jobs.args`.
    alter table(:tasks) do
      add :job_id, :bigint
    end

    execute """
    UPDATE tasks SET job_id = (e.data->>'job_id')::bigint
    FROM task_events e
    WHERE e.task_id = tasks.id AND e.type = 'enqueued'
    """

    # Not used by any query; (task_id, seq) covers the event lookups.
    drop index(:task_events, [:type, :occurred_at])

    to_integer(:task_events, :type, @event_types)
    to_integer(:tasks, :status, @statuses)
    to_integer(:task_logs, :source, @log_sources)

    execute "ALTER TABLE task_logs ALTER COLUMN level DROP DEFAULT"
    to_integer(:task_logs, :level, @log_levels)
    execute "ALTER TABLE task_logs ALTER COLUMN level SET DEFAULT #{@log_levels[:info]}"

    # A task row is updated several times per conversion; free space in each page
    # lets Postgres update it in place (HOT) when no indexed column changes.
    execute "ALTER TABLE tasks SET (fillfactor = 80)"
  end

  def down do
    execute "ALTER TABLE tasks RESET (fillfactor)"

    execute "ALTER TABLE task_logs ALTER COLUMN level DROP DEFAULT"
    to_string_column(:task_logs, :level, @log_levels)
    execute "ALTER TABLE task_logs ALTER COLUMN level SET DEFAULT 'info'"

    to_string_column(:task_logs, :source, @log_sources)
    to_string_column(:tasks, :status, @statuses)
    to_string_column(:task_events, :type, @event_types)

    create index(:task_events, [:type, :occurred_at])

    alter table(:tasks) do
      remove :job_id
    end
  end

  defp to_integer(table, column, mapping) do
    cases = Enum.map_join(mapping, " ", fn {name, code} -> "WHEN '#{name}' THEN #{code}" end)

    execute """
    ALTER TABLE #{table} ALTER COLUMN #{column} TYPE smallint
    USING (CASE #{column} #{cases} END)
    """
  end

  defp to_string_column(table, column, mapping) do
    cases = Enum.map_join(mapping, " ", fn {name, code} -> "WHEN #{code} THEN '#{name}'" end)

    execute """
    ALTER TABLE #{table} ALTER COLUMN #{column} TYPE varchar(255)
    USING (CASE #{column} #{cases} END)
    """
  end
end
