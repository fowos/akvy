defmodule Akvy.Release do
  @moduledoc """
  Tasks executed in production releases, where Mix is not available.

  Migrations run automatically when an instance boots (see `Akvy.Application`);
  these helpers are for manual use:

      bin/akvy eval "Akvy.Release.migrate()"
      bin/akvy eval 'Akvy.Release.create_admin("admin@example.com", "password")'
  """
  require Logger

  @app :akvy

  @doc "Creates the database if needed and runs all pending migrations for every repo."
  @spec migrate() :: [{:ok, [integer()], [atom()]}]
  def migrate do
    load_app()

    for repo <- repos() do
      ensure_storage(repo)
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Rolls `repo` back to migration `version`."
  @spec rollback(Ecto.Repo.t(), integer()) :: {:ok, [integer()], [atom()]}
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Creates the database on first deploy. Failures are logged, not raised: the
  database user may lack CREATE DATABASE rights while the database already exists.
  """
  @spec ensure_storage(Ecto.Repo.t()) :: :ok
  def ensure_storage(repo \\ Akvy.Repo) do
    case repo.__adapter__().storage_up(repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> Logger.warning("could not create the database: #{inspect(reason)}")
    end
  end

  @doc "Creates a confirmed admin user and prints the outcome."
  @spec create_admin(String.t(), String.t()) :: :ok
  def create_admin(email, password) do
    load_app()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(Akvy.Repo, fn _repo ->
        Akvy.Accounts.create_admin(%{email: email, password: password})
      end)

    case result do
      {:ok, user} -> IO.puts("Admin #{user.email} created")
      {:error, changeset} -> IO.puts("Could not create admin: #{inspect(changeset.errors)}")
    end
  end

  @spec repos() :: [Ecto.Repo.t()]
  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  @spec load_app() :: :ok | {:error, term()}
  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
