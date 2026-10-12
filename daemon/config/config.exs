import Config

config :helmsman_daemon, adapters: [HelmsmanDaemon.Adapters.Claude]

import_config "#{config_env()}.exs"
