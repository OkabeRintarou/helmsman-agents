# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :helmsman, :scopes,
  user: [
    default: true,
    module: Helmsman.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Helmsman.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :helmsman,
  ecto_repos: [Helmsman.Repo],
  generators: [timestamp_type: :utc_datetime]

# Authentication rate limits, as {limit, window_ms} per bucket.
config :helmsman, Helmsman.RateLimit,
  magic_link_ip: {5, :timer.minutes(1)},
  magic_link_email: {3, :timer.minutes(10)},
  password_ip: {10, :timer.minutes(1)},
  register_ip: {10, :timer.hours(1)},
  daemon_device_ip: {10, :timer.minutes(1)},
  daemon_device_user: {20, :timer.minutes(1)}

# Requests per minute per API token (designs/03 §2).
config :helmsman, :api_token_rate_limit, 600

# Background jobs (designs/15 §1): GitHub calls and syncs run in Oban.
config :helmsman, Oban,
  engine: Oban.Engines.Basic,
  repo: Helmsman.Repo,
  queues: [github: 5, github_sync: 1, github_pr: 3, default: 10, daemons: 2, runs: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 4 * * *", Helmsman.GitHub.Workers.SyncAll},
       {"30 4 * * *", Helmsman.GitHub.Workers.PruneDeliveries},
       {"* * * * *", Helmsman.Daemons.Workers.MarkOffline},
       {"15 3 * * *", Helmsman.Daemons.Workers.PruneDeviceCodes},
       {"* * * * *", Helmsman.Runs.Workers.Sweep},
       {"45 4 * * *", Helmsman.Runs.Workers.PruneEvents},
       {"*/15 * * * *", Helmsman.GitHub.Workers.ReconcileSweep}
     ]}
  ]

# GitHub endpoints; GitHub Enterprise is not supported (designs/00 §10).
config :helmsman, Helmsman.GitHub,
  api_url: "https://api.github.com",
  web_url: "https://github.com",
  # Automatic reopens of a pull request after CI failures or merge
  # conflicts before a person is asked (`add-pr-reconcile-merge` decision 9).
  max_auto_reopens: 3

# The instance's public base URL for links written outside the web layer
# (pull request bodies); `runtime.exs` sets it from PHX_HOST and PORT.
config :helmsman, :public_url, "http://localhost:4000"

# Configure the endpoint
config :helmsman, HelmsmanWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HelmsmanWeb.ErrorHTML, json: HelmsmanWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Helmsman.PubSub,
  live_view: [signing_salt: "3/nmaOep"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# UI copy is Chinese first (design D6): the "ui" gettext domain, default locale zh.
config :helmsman, HelmsmanWeb.Gettext, default_locale: "zh", locales: ~w(zh en)

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :helmsman, Helmsman.Mailer, adapter: Swoosh.Adapters.Local

# Sender of system emails; production reads HELMSMAN_MAILER_FROM.
config :helmsman, :mailer_from, {"Helmsman", "noreply@localhost"}

# How long an invitation link stays valid.
config :helmsman, :invitation_ttl_days, 7

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  helmsman: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # Mermaid in its own file, loaded only by pages that show a diagram (designs/09 §6).
  helmsman_mermaid: [
    args:
      ~w(js/mermaid.js --bundle --minify --format=iife --target=es2022 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../assets/node_modules", __DIR__)]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  helmsman: [
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

# Markdown code blocks are highlighted by Lumis (CSS classes, no inline
# styles); the languages are the `lumis_wasm_*` dependencies.
config :mdex_native, syntax_highlighter: :lumis

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
