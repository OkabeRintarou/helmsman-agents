import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
#
# DATABASE_URL, when set, replaces the default connection parameters
# (which match docker-compose.yml); the partition suffix is appended
# to its database name.
partition = System.get_env("MIX_TEST_PARTITION", "")

if database_url = System.get_env("DATABASE_URL") do
  uri = URI.parse(database_url)
  config :helmsman, Helmsman.Repo, url: URI.to_string(%{uri | path: uri.path <> partition})
else
  config :helmsman, Helmsman.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "helmsman_test#{partition}"
end

config :helmsman, Helmsman.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :helmsman, HelmsmanWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "W+MCHlrn8nM+wFnbRxWu3EAey+WI2+K996DxfeXkt6m+f1ZD12zk9qjgs2betm3n",
  server: false

# In test we don't send emails
config :helmsman, Helmsman.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
