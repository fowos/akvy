defmodule Akvy.Shutdown.HttpDrain do
  @moduledoc """
  First step of `Akvy.Shutdown`: takes the instance out of the load balancer and
  closes SSE streams before the endpoint stops. Must be the last supervised child.
  """
  use GenServer

  require Logger

  alias Akvy.Shutdown

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Shutdown.drain_ms() + 5_000
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
    Logger.info("shutdown: draining for #{Shutdown.drain_ms()} ms")
    Shutdown.mark_draining()
    pause_conversions()
    Process.sleep(Shutdown.drain_ms())
    Shutdown.notify_streams()
  end

  # New conversions go to other instances from now on.
  defp pause_conversions do
    Oban.pause_queue(queue: :convert, local_only: true)
  catch
    kind, reason -> Logger.warning("shutdown: pause failed: #{inspect({kind, reason})}")
  end
end
