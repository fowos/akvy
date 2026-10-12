defmodule Akvy.Shutdown.JobDrain do
  @moduledoc """
  Last step of `Akvy.Shutdown` before Oban stops: lets running conversions finish,
  hands the rest to other instances and releases this instance's downloads.
  Must be supervised right after Oban, so it stops after the endpoint and before Oban.
  """
  use GenServer

  import Ecto.Query
  require Logger

  alias Akvy.{Instance, Recovery, Repo, Shutdown}
  alias Akvy.Tasks.{Task, TaskEvent}

  @poll_ms 500

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Shutdown.jobs_ms() + 10_000
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    deadline = System.monotonic_time(:millisecond) + Shutdown.jobs_ms()
    left = wait_for_jobs(deadline)
    reason = "instance #{Instance.id()} shut down"

    if left != [] do
      Logger.info("shutdown: handing over #{length(left)} conversion(s)")

      from(j in Oban.Job, where: j.id in ^left)
      |> Repo.all()
      |> Enum.each(&Recovery.release_job(&1, reason, refund_attempt: true))
    end

    release_downloads(reason)
  end

  @doc """
  Releases downloads served by this instance. Called once the endpoint has stopped,
  so none of them can still be in progress here.
  """
  @spec release_downloads(String.t()) :: :ok
  def release_downloads(reason) do
    from(t in Task,
      join: e in TaskEvent,
      on: e.task_id == t.id and e.seq == t.version,
      where: t.status == :downloading and e.type == :download_started,
      where: e.node == ^Instance.id()
    )
    |> Repo.all()
    |> Enum.each(&Recovery.release_download(&1, reason))
  end

  # Returns ids of conversions still running at the deadline.
  @spec wait_for_jobs(integer()) :: [pos_integer()]
  defp wait_for_jobs(deadline) do
    case running() do
      [] ->
        []

      ids ->
        if System.monotonic_time(:millisecond) >= deadline do
          ids
        else
          Process.sleep(@poll_ms)
          wait_for_jobs(deadline)
        end
    end
  end

  defp running do
    case Oban.check_queue(queue: :convert) do
      %{running: ids} -> ids
      _ -> []
    end
  end
end
