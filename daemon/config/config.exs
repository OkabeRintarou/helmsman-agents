import Config

config :helmsman_daemon,
  adapters: [
    HelmsmanDaemon.Adapters.Claude,
    HelmsmanDaemon.Adapters.Codex,
    HelmsmanDaemon.Adapters.Copilot
  ]

import_config "#{config_env()}.exs"
