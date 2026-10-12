defmodule Akvy.Cluster do
  @moduledoc """
  Cluster membership and per-node load metrics for the admin panel.

  Nodes discover each other through Postgres (`LibclusterPostgres.Strategy`).
  Metrics are collected from every connected node with `:erpc.multicall/5`;
  each node keeps a short history of samples in `Akvy.Cluster.Sampler`.
  """

  alias Akvy.Cluster.Sampler

  @rpc_timeout 3_000

  @type ffmpeg_slots :: %{
          running: non_neg_integer(),
          limit: non_neg_integer(),
          paused: boolean()
        }

  @typedoc "Metrics of a reachable node; `:current?` is added by `nodes_info/0`."
  @type local_info :: %{
          optional(:current?) => boolean(),
          node: node(),
          instance: String.t(),
          reachable: true,
          version: String.t(),
          otp_release: String.t(),
          elixir_version: String.t(),
          uptime_ms: non_neg_integer(),
          schedulers: pos_integer(),
          run_queue: non_neg_integer(),
          process_count: non_neg_integer(),
          beam_memory: non_neg_integer(),
          system_memory_total: non_neg_integer() | nil,
          system_memory_available: non_neg_integer() | nil,
          cpu_percent: float() | nil,
          load1: float() | nil,
          ffmpeg: ffmpeg_slots(),
          history: [Sampler.sample()]
        }

  @typedoc "A node that did not answer; `error` is the inspected RPC error."
  @type unreachable_node :: %{
          optional(:current?) => boolean(),
          node: node(),
          instance: String.t(),
          reachable: false,
          error: String.t()
        }

  @type node_info :: local_info() | unreachable_node()

  @typedoc "Totals over reachable nodes; `cpu_percent` is their average."
  @type summary :: %{
          nodes: non_neg_integer(),
          reachable: non_neg_integer(),
          ffmpeg_running: non_neg_integer(),
          ffmpeg_limit: non_neg_integer(),
          schedulers: non_neg_integer(),
          cpu_percent: float() | nil,
          beam_memory: non_neg_integer(),
          run_queue: non_neg_integer()
        }

  @doc "Metrics of all nodes of the cluster (this node first). Unreachable nodes are flagged."
  @spec nodes_info() :: [node_info()]
  def nodes_info do
    nodes = [node() | Enum.sort(Node.list())]

    nodes
    |> :erpc.multicall(__MODULE__, :local_info, [], @rpc_timeout)
    |> Enum.zip(nodes)
    |> Enum.map(fn
      {{:ok, info}, _node} ->
        info

      {error, node} ->
        %{node: node, instance: Atom.to_string(node), reachable: false, error: inspect(error)}
    end)
    |> Enum.map(&Map.put(&1, :current?, &1.node == node()))
  end

  @doc "Cluster-wide totals computed from `nodes_info/0`."
  @spec summary([node_info()]) :: summary()
  def summary(nodes) do
    reachable = Enum.filter(nodes, & &1.reachable)
    sum = fn key -> reachable |> Enum.map(&(get_in(&1, key) || 0)) |> Enum.sum() end
    cpus = reachable |> Enum.map(& &1.cpu_percent) |> Enum.reject(&is_nil/1)

    %{
      nodes: length(nodes),
      reachable: length(reachable),
      ffmpeg_running: sum.([:ffmpeg, :running]),
      ffmpeg_limit: sum.([:ffmpeg, :limit]),
      schedulers: sum.([:schedulers]),
      cpu_percent: if(cpus == [], do: nil, else: Enum.sum(cpus) / length(cpus)),
      beam_memory: sum.([:beam_memory]),
      run_queue: sum.([:run_queue])
    }
  end

  @doc "Metrics of the local node. Called remotely by `nodes_info/0`."
  @spec local_info() :: local_info()
  def local_info do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    memory = system_memory()

    %{
      node: node(),
      instance: Akvy.Instance.id(),
      reachable: true,
      version: Application.spec(:akvy, :vsn) |> to_string(),
      otp_release: :erlang.system_info(:otp_release) |> to_string(),
      elixir_version: System.version(),
      uptime_ms: uptime_ms,
      schedulers: :erlang.system_info(:schedulers_online),
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      process_count: :erlang.system_info(:process_count),
      beam_memory: :erlang.memory(:total),
      system_memory_total: memory[:total],
      system_memory_available: memory[:available],
      cpu_percent: Sampler.latest_cpu(),
      load1: load1(),
      ffmpeg: ffmpeg_slots(),
      history: Sampler.history()
    }
  end

  @doc "Running and maximum ffmpeg jobs of the local node; zeros when Oban is unavailable."
  @spec ffmpeg_slots() :: ffmpeg_slots()
  def ffmpeg_slots do
    case Oban.check_queue(queue: :convert) do
      %{limit: limit, running: running, paused: paused} ->
        %{running: length(running), limit: limit, paused: paused}

      _ ->
        %{running: 0, limit: 0, paused: false}
    end
  rescue
    _ -> %{running: 0, limit: 0, paused: false}
  catch
    :exit, _ -> %{running: 0, limit: 0, paused: false}
  end

  @spec system_memory() ::
          %{total: non_neg_integer() | nil, available: non_neg_integer() | nil} | %{}
  defp system_memory do
    data = :memsup.get_system_memory_data()
    total = data[:system_total_memory] || data[:total_memory]
    available = data[:available_memory] || data[:free_memory]
    %{total: total, available: available}
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc "Whether `:cpu_sup` can report utilization and load averages (Unix only)."
  @spec cpu_sup_available?() :: boolean()
  def cpu_sup_available?, do: match?({:unix, _}, :os.type())

  @spec load1() :: float() | nil
  defp load1 do
    with true <- cpu_sup_available?(),
         value when is_integer(value) <- :cpu_sup.avg1() do
      Float.round(value / 256, 2)
    else
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end
end
