import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :media_assist, MediaAssist.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "media_assist_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :media_assist, MediaAssistWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "rKGph6Jrgs2IHSp99nKAYAM66mY3fbYwGuiQLQFcv95va2uPbwK01gKE6LUoKXhS",
  server: false

# In test we don't send emails
config :media_assist, MediaAssist.Mailer, adapter: Swoosh.Adapters.Test

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

# Static test-only encryption key for secrets at rest
config :media_assist, MediaAssist.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("kply5fDmbIBPv4BGd66Lq8tnK3/j+/haDF+2TkXBFzE="),
       iv_length: 12}
  ]

# Run Oban inline assertions manually in tests
config :media_assist, Oban, testing: :manual
