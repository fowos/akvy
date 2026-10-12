defmodule Akvy.Heartbeat do
  @moduledoc """
  Periodically marks this instance boot as alive in `instance_heartbeats`.

  Timestamps come from the database clock, so instances with skewed clocks agree.
  `Akvy.Workers.RescueOrphans` treats work of boots without a fresh heartbeat as lost.
  """
  use GenServer

  require Logger

  alias Akvy.Repo

  @interval :timer.seconds(10)

  @doc "Seconds without a heartbeat after which a boot is considered dead."
  @spec stale_after() :: pos_integer()
  def stale_after, do: 60

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Writes one heartbeat for `boot_id`; `producer_uuid` is the current `convert` producer."
  @spec beat(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) :: :ok
  def beat(boot_id, instance, producer_uuid) do
    Repo.query!(
      """
      INSERT INTO instance_heartbeats (boot_id, instance, producer_uuid, started_at, seen_at)
      VALUES ($1, $2, $3, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      ON CONFLICT (boot_id)
      DO UPDATE SET producer_uuid = EXCLUDED.producer_uuid, seen_at = EXCLUDED.seen_at
      """,
      [dump_uuid(boot_id), instance, producer_uuid && dump_uuid(producer_uuid)]
    )

    :ok
  end

  @impl true
  def init(_opts) do
    {:ok, %{boot_id: Ecto.UUID.generate()}, {:continue, :beat}}
  end

  @impl true
  def handle_continue(:beat, state) do
    do_beat(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:beat, state) do
    do_beat(state)
    {:noreply, state}
  end

  defp do_beat(state) do
    beat(state.boot_id, Akvy.Instance.id(), producer_uuid())
  rescue
    error -> Logger.warning("heartbeat failed: #{Exception.message(error)}")
  after
    Process.send_after(self(), :beat, @interval)
  end

  @spec producer_uuid() :: Ecto.UUID.t() | nil
  defp producer_uuid do
    case Oban.check_queue(queue: :convert) do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  defp dump_uuid(uuid), do: Ecto.UUID.dump!(uuid)
end
