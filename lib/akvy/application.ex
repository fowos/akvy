defmodule Akvy.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc "OTP application: migrates (in releases) and starts the supervision tree."

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    instance_id = Akvy.Instance.init()
    migrate? = auto_migrate?()

    if migrate?, do: Akvy.Release.ensure_storage()

    children = [
      AkvyWeb.Telemetry,
      Akvy.Repo,
      # Every instance migrates on boot; the Postgres advisory lock
      # (`migration_lock: :pg_advisory_lock`) lets only one of them run migrations at a time.
      {Ecto.Migrator, repos: Application.fetch_env!(:akvy, :ecto_repos), skip: not migrate?},
      # Erlang cluster discovery through the shared database (LISTEN/NOTIFY heartbeats).
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies, []), [name: Akvy.ClusterSupervisor]]},
      {Phoenix.PubSub, name: Akvy.PubSub},
      {Oban, Keyword.put(Application.fetch_env!(:akvy, Oban), :node, instance_id)},
      # Liveness marker used to rescue this instance's work if it dies; reads the Oban producer.
      heartbeat_enabled?() && Akvy.Heartbeat,
      # Stops after the endpoint and before Oban: finishes or hands over conversions.
      Akvy.Shutdown.enabled?() && Akvy.Shutdown.JobDrain,
      Akvy.Cluster.Sampler,
      {Task, &ensure_bucket/0},
      # Start to serve requests, typically the last entry
      AkvyWeb.Endpoint,
      # Stops first: takes the instance out of the load balancer (see Akvy.Shutdown).
      Akvy.Shutdown.enabled?() && Akvy.Shutdown.HttpDrain
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Akvy.Supervisor]
    Supervisor.start_link(Enum.filter(children, & &1), opts)
  end

  # Migrations run automatically in releases unless AUTO_MIGRATE=false.
  # In development and tests they are run with mix.
  defp auto_migrate? do
    System.get_env("RELEASE_NAME") != nil and System.get_env("AUTO_MIGRATE") != "false"
  end

  defp heartbeat_enabled?, do: Application.get_env(:akvy, Akvy.Heartbeat)[:enabled] == true

  defp ensure_bucket do
    case Akvy.Storage.ensure_bucket() do
      :ok -> :ok
      {:error, reason} -> Logger.error("storage bucket check failed: #{inspect(reason)}")
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AkvyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
