defmodule Akvy.ClusterTest do
  use ExUnit.Case, async: true

  alias Akvy.Cluster

  test "nodes_info/0 reports the local node" do
    assert [%{reachable: true, current?: true} = info] = Cluster.nodes_info()

    assert info.instance == Akvy.Instance.id()
    assert info.schedulers > 0
    assert info.beam_memory > 0
    assert %{running: _, limit: _} = info.ffmpeg
    assert is_list(info.history)
  end

  test "summary/1 aggregates reachable nodes" do
    nodes = [
      %{
        reachable: true,
        ffmpeg: %{running: 1, limit: 2},
        schedulers: 4,
        cpu_percent: 50.0,
        beam_memory: 10,
        run_queue: 1
      },
      %{
        reachable: true,
        ffmpeg: %{running: 2, limit: 2},
        schedulers: 4,
        cpu_percent: nil,
        beam_memory: 20,
        run_queue: 0
      },
      %{reachable: false, node: :"akvy@10.0.0.3"}
    ]

    assert %{
             nodes: 3,
             reachable: 2,
             ffmpeg_running: 3,
             ffmpeg_limit: 4,
             schedulers: 8,
             cpu_percent: 50.0,
             beam_memory: 30
           } = Cluster.summary(nodes)
  end
end
