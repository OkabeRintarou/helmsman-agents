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

if config_env() == :dev do
  config :helmsman,
         :public_url,
         "http://#{System.get_env("PHX_HOST", "localhost")}:#{System.get_env("PORT", "4000")}"
end

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
  # An empty variable (`NAME=` in a compose env file) counts as unset: a
  # required one is missing, an optional one takes its default.
  required_env = fn name ->
    case System.get_env(name) do
      "" -> nil
      value -> value
    end
  end

  env = fn name, default -> required_env.(name) || default end

  database_url =
    required_env.("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :helmsman, Helmsman.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "15"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    required_env.("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  vault_key =
    case required_env.("HELMSMAN_VAULT_KEY") do
      nil ->
        raise """
        environment variable HELMSMAN_VAULT_KEY is missing.
        It is the base64 encoding of a random 32-byte key, for example:
        openssl rand -base64 32
        """

      encoded ->
        case Base.decode64(encoded) do
          {:ok, <<_::binary-size(32)>> = key} ->
            key

          _ ->
            raise "environment variable HELMSMAN_VAULT_KEY must be the base64 encoding " <>
                    "of exactly 32 bytes"
        end
    end

  config :helmsman, Helmsman.Vault,
    ciphers: [default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: vault_key}]

  host =
    required_env.("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      It is the host name users and daemons reach this instance at, for example: hm.example.com
      """

  # The public URL (add-release-distribution decision 3): https on 443 unless
  # set otherwise, e.g. PHX_URL_SCHEME=http and PHX_URL_PORT=4000 on a
  # private network without TLS.
  url_scheme =
    case env.("PHX_URL_SCHEME", "https") do
      scheme when scheme in ["https", "http"] ->
        scheme

      other ->
        raise "environment variable PHX_URL_SCHEME has an invalid value: #{inspect(other)}. " <>
                "Allowed values: https, http"
    end

  url_port =
    case env.("PHX_URL_PORT", "") do
      "" ->
        URI.default_port(url_scheme)

      value ->
        case Integer.parse(value) do
          {port, ""} when port in 1..65_535 ->
            port

          _ ->
            raise "environment variable PHX_URL_PORT must be a port number, got: #{inspect(value)}"
        end
    end

  public_url =
    if url_port == URI.default_port(url_scheme),
      do: "#{url_scheme}://#{host}",
      else: "#{url_scheme}://#{host}:#{url_port}"

  config :helmsman, :public_url, public_url

  # Secure cookies, the HTTPS redirect and HSTS follow the public scheme.
  config :helmsman,
    secure_cookies: url_scheme == "https",
    force_ssl: url_scheme == "https"

  # Reverse proxies whose X-Forwarded-For / X-Forwarded-Proto are honoured
  # (HelmsmanWeb.Plugs.TrustedProxies); none by default.
  trusted_proxies =
    "HELMSMAN_TRUSTED_PROXIES"
    |> env.("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  for cidr <- trusted_proxies do
    {address, prefix} =
      case String.split(cidr, "/", parts: 2) do
        [address, prefix] -> {address, Integer.parse(prefix)}
        [address] -> {address, nil}
      end

    valid? =
      case {:inet.parse_strict_address(String.to_charlist(address)), prefix} do
        {{:ok, _ip}, nil} -> true
        {{:ok, ip}, {bits, ""}} when tuple_size(ip) == 4 -> bits in 0..32
        {{:ok, ip}, {bits, ""}} when tuple_size(ip) == 8 -> bits in 0..128
        _ -> false
      end

    valid? ||
      raise "environment variable HELMSMAN_TRUSTED_PROXIES has an invalid entry: #{inspect(cidr)}. " <>
              "Expected comma-separated IP addresses or CIDR ranges, e.g. 10.0.0.0/8,172.16.0.0/12"
  end

  config :helmsman, :trusted_proxies, trusted_proxies

  # Export and import files (designs/11 §3).
  config :helmsman, :data_dir, env.("HELMSMAN_DATA_DIR", "/var/lib/helmsman")

  # Daemon binaries served by /downloads/daemon/* (decision 11): from this
  # directory, else redirected to HELMSMAN_DAEMON_DOWNLOAD_URL/helmsman-<target>.
  config :helmsman, :daemon_dist_dir, env.("HELMSMAN_DAEMON_DIST_DIR", nil)

  daemon_download_url =
    case env.("HELMSMAN_DAEMON_DOWNLOAD_URL", "") do
      "" ->
        nil

      url ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host}
          when scheme in ["https", "http"] and host not in [nil, ""] ->
            String.trim_trailing(url, "/")

          _ ->
            raise "environment variable HELMSMAN_DAEMON_DOWNLOAD_URL must be an http(s) URL, " <>
                    "got: #{inspect(url)}"
        end
    end

  config :helmsman, :daemon_download_url, daemon_download_url

  config :helmsman, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :helmsman, HelmsmanWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
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

  # ## Logging (decision 6)
  #
  # HELMSMAN_LOG_FORMAT: json (the default in a release) or text;
  # HELMSMAN_LOG_LEVEL: debug, info (default), notice, warning or error.
  # JSON lines keep only this metadata; never tokens, secrets or agent
  # environments.
  log_metadata = [
    :request_id,
    :workspace_id,
    :user_id,
    :agent_id,
    :mcp_definition_name,
    :server_name,
    :action,
    :token_id,
    :api_actor,
    :run_id,
    :daemon_id,
    :mcp_tool,
    :actor,
    :duration_ms,
    :result
  ]

  log_level =
    case env.("HELMSMAN_LOG_LEVEL", "info") do
      level when level in ~w(debug info notice warning error) ->
        String.to_atom(level)

      other ->
        raise "environment variable HELMSMAN_LOG_LEVEL has an invalid value: #{inspect(other)}. " <>
                "Allowed values: debug, info, notice, warning, error"
    end

  config :logger, level: log_level

  default_log_format = if System.get_env("RELEASE_NAME"), do: "json", else: "text"

  case env.("HELMSMAN_LOG_FORMAT", default_log_format) do
    "json" ->
      config :logger, :default_handler,
        formatter: LoggerJSON.Formatters.Basic.new(metadata: log_metadata)

    "text" ->
      config :logger, :default_formatter, metadata: log_metadata

    other ->
      raise "environment variable HELMSMAN_LOG_FORMAT has an invalid value: #{inspect(other)}. " <>
              "Allowed values: json, text"
  end
end
