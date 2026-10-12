import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :akvy, Akvy.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "akvy_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :akvy, AkvyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "1ah88L/zxbfkhqUZGFiVVUbOaFOHJNv353azmAJzR/R9H4dHrg2Deau/otNHgneE",
  server: false

# Print only warnings and errors during test
config :akvy, Oban, testing: :manual

config :akvy, Akvy.Storage,
  adapter: Akvy.Storage.Local,
  root: Path.join(System.tmp_dir!(), "akvy_test_storage")

config :akvy, Akvy.FFmpeg, runner: Akvy.FakeFFmpeg

config :akvy, :work_dir, Path.join(System.tmp_dir!(), "akvy_test_work")

config :akvy, Akvy.Mailer, adapter: Swoosh.Adapters.Test

config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
