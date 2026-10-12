defmodule Mix.Tasks.Akvy.CreateAdmin do
  @shortdoc "Creates an admin user for the admin panel"

  @moduledoc """
  Creates a confirmed admin user.

      mix akvy.create_admin admin@example.com "a long password"

  In a release use: `bin/akvy eval 'Akvy.Release.create_admin("email", "password")'`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run([email, password]) do
    case Akvy.Accounts.create_admin(%{email: email, password: password}) do
      {:ok, user} ->
        Mix.shell().info("Admin #{user.email} created")

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {k, v}, acc ->
              String.replace(acc, "%{#{k}}", to_string(v))
            end)
          end)

        Mix.raise("Could not create admin: #{inspect(errors)}")
    end
  end

  def run(_args), do: Mix.raise("Usage: mix akvy.create_admin EMAIL PASSWORD")
end
