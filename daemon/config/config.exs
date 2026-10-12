import Config

config :helmsman_daemon, adapters: []

import_config "#{config_env()}.exs"
