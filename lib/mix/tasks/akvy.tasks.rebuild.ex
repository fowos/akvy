defmodule Mix.Tasks.Akvy.Tasks.Rebuild do
  @shortdoc "Rebuilds task snapshots from their event history"

  @moduledoc """
  Recomputes the `tasks` snapshot rows from `task_events`.

      mix akvy.tasks.rebuild TASK_ID [TASK_ID...]
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run([]), do: Mix.raise("Usage: mix akvy.tasks.rebuild TASK_ID [TASK_ID...]")

  def run(ids) do
    for id <- ids do
      case Akvy.Tasks.rebuild_snapshot(id) do
        {:ok, task} -> Mix.shell().info("#{id}: #{task.status} (version #{task.version})")
        {:error, reason} -> Mix.shell().error("#{id}: #{inspect(reason)}")
      end
    end
  end
end
