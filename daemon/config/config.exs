import Config

# Cursor stays off until the daemon config has `[cursor] enabled = true`.
config :helmsman_daemon,
  adapters: [
    HelmsmanDaemon.Adapters.Claude,
    HelmsmanDaemon.Adapters.Codex,
    HelmsmanDaemon.Adapters.Copilot,
    HelmsmanDaemon.Adapters.Cursor
  ]

import_config "#{config_env()}.exs"
