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
      Akvy.Cluster.Sampler,
      {Task, &ensure_bucket/0},
      # Start to serve requests, typically the last entry
      AkvyWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Akvy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Migrations run automatically in releases unless AUTO_MIGRATE=false.
  # In development and tests they are run with mix.
  defp auto_migrate? do
    System.get_env("RELEASE_NAME") != nil and System.get_env("AUTO_MIGRATE") != "false"
  end

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
