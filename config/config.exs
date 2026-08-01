# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :media_assist, :scopes,
  user: [
    default: true,
    module: MediaAssist.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: MediaAssist.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :media_assist,
  ecto_repos: [MediaAssist.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Custom Postgrex types so Ecto can read/write pgvector columns
config :media_assist, MediaAssist.Repo, types: MediaAssist.PostgrexTypes

# Background jobs: the :indexer queue runs media cache syncs
config :media_assist, Oban,
  repo: MediaAssist.Repo,
  engine: Oban.Engines.Basic,
  queues: [indexer: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    # Frequent tick; the scheduler itself decides whether a sync is due
    # from the runtime `sync_interval_minutes` setting.
    {Oban.Plugins.Cron, crontab: [{"*/10 * * * *", MediaAssist.Media.SyncSchedulerWorker}]}
  ]

# Configure the endpoint
config :media_assist, MediaAssistWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MediaAssistWeb.ErrorHTML, json: MediaAssistWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MediaAssist.PubSub,
  live_view: [signing_salt: "42wtdauL"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :media_assist, MediaAssist.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  media_assist: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  media_assist: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
