import Config

config :helmsman_daemon, adapters: [HelmsmanDaemon.Adapters.Claude, HelmsmanDaemon.Adapters.Codex]

import_config "#{config_env()}.exs"
