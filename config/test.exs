import Config

config :ash,
  disable_async?: true,
  policies: [show_policy_breakdowns?: true],
  keyset_signing_secret: "obW9rUu3RchUNfGU0vY9/oYFd+zaaRS2U46pBhn6I7Y"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :lovelace, Lovelace.Repo,
  database: Path.expand("../lovelace_test.db", __DIR__),
  # SQLite sandbox tests are serialized; one connection also avoids fresh-file startup contention.
  pool_size: 1,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :lovelace, LovelaceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "5RWMr/bQJIQMHlZzKnTdqUwnQlqIKscplAQBLI72Rd5xZ/Cg7njm4UAj2lm7s/2N",
  server: false

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
