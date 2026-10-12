defmodule Akvy.Cluster.Sampler do
  @moduledoc """
  Samples local CPU utilization and ffmpeg slot usage every few seconds and keeps
  a short history (for sparklines in the admin panel). One sampler runs per node.
  """
  use GenServer

  @interval_ms 5_000
  @history 60
  @table __MODULE__

  @typedoc "`cpu` is utilization in percent (nil when unsupported); `ffmpeg` is running jobs."
  @type sample :: %{at: DateTime.t(), cpu: float() | nil, ffmpeg: non_neg_integer()}

  @doc "Starts the node's sampler, registered under the module name."
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Most recent CPU utilization in percent, nil when unsupported by the OS."
  @spec latest_cpu() :: float() | nil
  def latest_cpu do
    case history() do
      [] -> nil
      list -> List.last(list).cpu
    end
  end

  @doc "Samples, oldest first; empty when the sampler is not running."
  @spec history() :: [sample()]
  def history do
    case :ets.whereis(@table) do
      :undefined -> []
      _ -> @table |> :ets.lookup(:history) |> Keyword.get(:history, [])
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.insert(@table, {:history, []})
    # The first call initializes cpu_sup's baseline for this process.
    cpu_util()
    send(self(), :sample)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sample, state) do
    sample = %{
      at: DateTime.utc_now(),
      cpu: cpu_util(),
      ffmpeg: Akvy.Cluster.ffmpeg_slots().running
    }

    history = Enum.take(history() ++ [sample], -@history)
    :ets.insert(@table, {:history, history})
    Process.send_after(self(), :sample, @interval_ms)
    {:noreply, state}
  end

  # Utilization since the previous call from this process.
  @spec cpu_util() :: float() | nil
  defp cpu_util do
    with true <- Akvy.Cluster.cpu_sup_available?(),
         value when is_number(value) <- :cpu_sup.util() do
      Float.round(value * 1.0, 1)
    else
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end
end
