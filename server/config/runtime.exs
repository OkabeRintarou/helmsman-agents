import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/helmsman start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :helmsman, HelmsmanWeb.Endpoint, server: true
end

config :helmsman, HelmsmanWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# The test suite selects the signup mode itself (config/test.exs).
if config_env() != :test do
  signup_mode =
    case System.get_env("HELMSMAN_SIGNUP", "invite") do
      "invite" ->
        :invite

      "open" ->
        :open

      other ->
        raise """
        environment variable HELMSMAN_SIGNUP has an invalid value: #{inspect(other)}.
        Allowed values: invite, open
        """
    end

  config :helmsman, :signup_mode, signup_mode
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :helmsman, HelmsmanWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/helmsman_web/router\.ex$"E,
        ~r"lib/helmsman_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :helmsman, Helmsman.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :helmsman, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :helmsman, HelmsmanWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :helmsman, HelmsmanWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :helmsman, HelmsmanWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Mailer
  #
  # HELMSMAN_MAILER_ADAPTER must be set explicitly: `smtp`, or `log` to only
  # write emails (including login links) to the log.
  mailer_help = """
  Set HELMSMAN_MAILER_ADAPTER to one of:
    smtp - deliver through an SMTP relay. Variables:
           HELMSMAN_MAILER_SMTP_HOST (required),
           HELMSMAN_MAILER_SMTP_PORT (default 587),
           HELMSMAN_MAILER_SMTP_USERNAME, HELMSMAN_MAILER_SMTP_PASSWORD,
           HELMSMAN_MAILER_SMTP_TLS (always | if_available, default if_available)
    log  - write emails, including login links, to the log only
  """

  case System.get_env("HELMSMAN_MAILER_ADAPTER") do
    "smtp" ->
      smtp_host =
        System.get_env("HELMSMAN_MAILER_SMTP_HOST") ||
          raise "environment variable HELMSMAN_MAILER_SMTP_HOST is missing.\n" <> mailer_help

      smtp_tls =
        case System.get_env("HELMSMAN_MAILER_SMTP_TLS", "if_available") do
          "always" ->
            :always

          "if_available" ->
            :if_available

          other ->
            raise "environment variable HELMSMAN_MAILER_SMTP_TLS has an invalid value: " <>
                    "#{inspect(other)}.\n" <> mailer_help
        end

      smtp_username = System.get_env("HELMSMAN_MAILER_SMTP_USERNAME")

      config :helmsman, Helmsman.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_host,
        port: String.to_integer(System.get_env("HELMSMAN_MAILER_SMTP_PORT", "587")),
        username: smtp_username,
        password: System.get_env("HELMSMAN_MAILER_SMTP_PASSWORD"),
        auth: if(smtp_username, do: :always, else: :never),
        ssl: false,
        tls: smtp_tls,
        tls_options: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(smtp_host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          depth: 99
        ],
        retries: 2

    "log" ->
      # Helmsman.Application logs a warning at startup for this adapter.
      config :helmsman, Helmsman.Mailer, adapter: Swoosh.Adapters.Logger, log_full_email: true

    nil ->
      raise "environment variable HELMSMAN_MAILER_ADAPTER is missing.\n" <> mailer_help

    other ->
      raise "environment variable HELMSMAN_MAILER_ADAPTER has an invalid value: " <>
              "#{inspect(other)}.\n" <> mailer_help
  end

  mailer_from = System.get_env("HELMSMAN_MAILER_FROM", "Helmsman <noreply@#{host}>")

  mailer_from =
    case Regex.run(~r/^\s*(.*?)\s*<([^<>\s]+)>\s*$/, mailer_from) do
      [_, name, address] -> {name, address}
      nil -> {"", String.trim(mailer_from)}
    end

  config :helmsman, :mailer_from, mailer_from
end
