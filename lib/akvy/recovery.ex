defmodule Akvy.Recovery do
  @moduledoc """
  Takes conversion jobs and downloads away from an instance that can no longer
  finish them (dead, see `Akvy.Workers.RescueOrphans`, or stopping, see `Akvy.Shutdown`).
  """
  import Ecto.Query
  require Logger

  alias Akvy.{Repo, Tasks}
  alias Akvy.Tasks.Task

  @type release_option :: {:refund_attempt, boolean()}

  @doc """
  Moves an executing conversion job back to `available`, or to `discarded` when it
  was the last attempt, and records the lost attempt in the task history.

  `refund_attempt: true` does not count the attempt (the job was interrupted, not failed).
  A no-op if the job finished meanwhile.
  """
  @spec release_job(Oban.Job.t(), String.t(), [release_option()]) :: :ok
  def release_job(%Oban.Job{} = job, reason, opts \\ []) do
    refund? = Keyword.get(opts, :refund_attempt, false)
    attempt = if refund?, do: max(job.attempt - 1, 0), else: job.attempt
    retry? = attempt < job.max_attempts
    now = DateTime.utc_now()
    error = %{attempt: job.attempt, at: now, error: reason}

    # Matching attempted_at makes this a no-op if the job was acked meanwhile.
    query =
      from j in Oban.Job,
        where: j.id == ^job.id and j.state == "executing" and j.attempted_at == ^job.attempted_at,
        update: [
          set: [
            state: ^if(retry?, do: "available", else: "discarded"),
            attempt: ^attempt,
            scheduled_at: ^now,
            discarded_at: ^if(retry?, do: nil, else: now),
            errors: fragment("? || ?", j.errors, ^[error])
          ]
        ]

    case Repo.update_all(query, []) do
      {1, _} ->
        Logger.warning("released job #{job.id}: #{reason}")
        fail_attempt(job.args["task_id"], reason, retry?, attempt + 1)

      _ ->
        :ok
    end
  end

  @doc "Releases the download lock of a task whose serving instance is gone."
  @spec release_download(Task.t(), String.t()) :: :ok
  def release_download(%Task{} = task, reason) do
    Logger.warning("released download of #{task.id}: #{reason}")

    with {:error, error} <- Tasks.abort_download(task) do
      Logger.warning("release of download #{task.id} failed: #{inspect(error)}")
    end

    :ok
  end

  # Mirrors Akvy.Workers.Convert failure handling.
  @spec fail_attempt(UUIDv7.t() | nil, String.t(), boolean(), pos_integer()) :: :ok
  defp fail_attempt(task_id, reason, retry?, next_attempt) do
    data = %{"error" => reason, "stage" => "instance_lost"}

    result =
      case task_id && Tasks.get_task(task_id) do
        %Task{status: :processing} = task ->
          with {:ok, task, _} <- Tasks.record_fresh(task, :attempt_failed, data: data) do
            finish_attempt(task, reason, retry?, next_attempt)
          end

        %Task{status: status} = task when status in [:uploaded, :retrying] and not retry? ->
          finish_attempt(task, reason, false, next_attempt)

        _ ->
          :ok
      end

    with {:error, error} <- result do
      Logger.warning("release of task #{task_id} failed: #{inspect(error)}")
    end

    :ok
  end

  @spec finish_attempt(Task.t(), String.t(), boolean(), pos_integer()) :: :ok | {:error, term()}
  defp finish_attempt(task, _reason, true, next_attempt) do
    data = %{"next_attempt" => next_attempt}
    with {:ok, _task, _} <- Tasks.record_fresh(task, :retry_scheduled, data: data), do: :ok
  end

  defp finish_attempt(task, reason, false, _next_attempt) do
    with {:ok, task, _} <- Tasks.record_fresh(task, :failed, data: %{"error" => reason}),
         {:ok, _task} <- Tasks.delete_input(task) do
      :ok
    end
  end
end
