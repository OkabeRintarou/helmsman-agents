import Config

config :helmsman_daemon, adapters: [HelmsmanDaemon.Adapters.Fake]

# Tests use the credentials file on every platform; keychain tests opt in.
config :helmsman_daemon, credentials_store: :file

# Tests never reach the real service manager; service tests inject an executor.
config :helmsman_daemon, service_cmd: {HelmsmanDaemon.TestServiceCmd, :run}
