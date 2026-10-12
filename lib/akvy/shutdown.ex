defmodule Akvy.Shutdown do
  @moduledoc """
  Graceful shutdown on SIGTERM. The supervisor stops children in reverse order:

    1. `Akvy.Shutdown.HttpDrain` (last child): `/health` turns 503, local conversions
       pause; after `drain_ms` SSE streams are closed so the endpoint stops quickly.
    2. `AkvyWeb.Endpoint` stops: in-flight requests get the Bandit shutdown timeout.
    3. `Akvy.Shutdown.JobDrain` (right after Oban): waits up to `jobs_ms` for running
       conversions, hands the rest to other instances without spending an attempt and
       releases this instance's downloads.
    4. Oban stops and kills what is left (ffmpeg is killed with its job).
  """

  @draining_key {__MODULE__, :draining}
  @topic "akvy:shutdown"

  @doc "Whether the shutdown handlers are supervised (disabled in tests)."
  @spec enabled?() :: boolean()
  def enabled?, do: config()[:enabled] == true

  @doc "Time the instance keeps serving after `/health` turns 503."
  @spec drain_ms() :: non_neg_integer()
  def drain_ms, do: Keyword.get(config(), :drain_ms, 5_000)

  @doc "Time running conversions get to finish before they are handed over."
  @spec jobs_ms() :: non_neg_integer()
  def jobs_ms, do: Keyword.get(config(), :jobs_ms, 30_000)

  @doc "True once the instance started shutting down."
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@draining_key, false)

  @doc false
  @spec mark_draining() :: :ok
  def mark_draining, do: :persistent_term.put(@draining_key, true)

  @doc "Subscribes the caller to `:akvy_shutdown`, sent to local SSE streams before the endpoint stops."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Akvy.PubSub, @topic)

  @doc false
  @spec notify_streams() :: :ok
  def notify_streams, do: Phoenix.PubSub.local_broadcast(Akvy.PubSub, @topic, :akvy_shutdown)

  @spec config() :: keyword()
  defp config, do: Application.get_env(:akvy, __MODULE__, [])
end
