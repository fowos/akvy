import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/akvy start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :akvy, AkvyWeb.Endpoint, server: true
end

config :akvy, AkvyWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() != :test do
  # S3-compatible storage (RustFS, MinIO, AWS S3). Path-style addressing is used.
  s3_uri = URI.parse(System.get_env("S3_ENDPOINT", "http://localhost:9000"))

  config :ex_aws,
    access_key_id: System.get_env("AWS_ACCESS_KEY_ID", "rustfsadmin"),
    secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY", "rustfsadmin"),
    region: System.get_env("S3_REGION", "us-east-1")

  config :ex_aws, :s3,
    scheme: "#{s3_uri.scheme}://",
    host: s3_uri.host,
    port: s3_uri.port,
    region: System.get_env("S3_REGION", "us-east-1"),
    virtual_host: false

  config :akvy, Akvy.Storage,
    adapter: Akvy.Storage.S3,
    bucket: System.get_env("S3_BUCKET", "akvy")

  config :akvy, Akvy.FFmpeg, path: System.get_env("FFMPEG_PATH", "ffmpeg")

  if work_dir = System.get_env("WORK_DIR") do
    config :akvy, :work_dir, work_dir
  end

  ffmpeg_concurrency =
    String.to_integer(System.get_env("FFMPEG_CONCURRENCY") || "#{System.schedulers_online()}")

  config :akvy, Oban, queues: [convert: ffmpeg_concurrency, maintenance: 1]

  # Graceful shutdown budget (see Akvy.Shutdown). Keep the container stop timeout above
  # SHUTDOWN_DRAIN_SECONDS + 15 s (HTTP) + SHUTDOWN_JOBS_SECONDS + 2 s.
  config :akvy, Akvy.Shutdown,
    drain_ms: String.to_integer(System.get_env("SHUTDOWN_DRAIN_SECONDS", "5")) * 1000,
    jobs_ms: String.to_integer(System.get_env("SHUTDOWN_JOBS_SECONDS", "30")) * 1000
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :akvy, AkvyWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/akvy_web/router\.ex$"E,
        ~r"lib/akvy_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :akvy, Akvy.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # Erlang cluster discovery through the shared Postgres database: every node
  # NOTIFYs its node name on a channel and connects to the names it receives.
  # Nodes must share RELEASE_COOKIE and reach each other (EPMD 4369 + distribution port).
  if System.get_env("CLUSTER_ENABLED", "true") == "true" do
    db = URI.parse(database_url)
    [username, password] = String.split(db.userinfo || "postgres:", ":", parts: 2)

    config :libcluster,
      topologies: [
        akvy: [
          strategy: LibclusterPostgres.Strategy,
          config: [
            hostname: db.host,
            port: db.port || 5432,
            username: URI.decode(username),
            password: URI.decode(password),
            database: String.trim_leading(db.path || "", "/"),
            channel_name: System.get_env("CLUSTER_CHANNEL", "akvy_cluster"),
            heartbeat_interval: 5_000
          ]
        ]
      ]
  end

  config :akvy, AkvyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :akvy, AkvyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :akvy, AkvyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
