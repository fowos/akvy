defmodule Akvy.Repo do
  @moduledoc "Ecto repository backed by PostgreSQL."
  use Ecto.Repo,
    otp_app: :akvy,
    adapter: Ecto.Adapters.Postgres
end
