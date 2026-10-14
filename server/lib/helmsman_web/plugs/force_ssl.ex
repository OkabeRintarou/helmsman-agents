defmodule HelmsmanWeb.Plugs.ForceSSL do
  @moduledoc """
  `Plug.SSL` decided at runtime: when the public URL is https
  (`config :helmsman, :force_ssl`, set from `PHX_URL_SCHEME`), plain HTTP
  requests are redirected to the configured host (and its port, when the
  public URL is https on a port other than 443) and responses carry HSTS; with `PHX_URL_SCHEME=http` nothing changes.

  It runs after `HelmsmanWeb.Plugs.TrustedProxies`, so only a trusted
  proxy's `X-Forwarded-Proto` counts. `localhost` and `127.0.0.1` are
  excluded (local health checks and smoke tests).
  """

  @behaviour Plug

  @ssl Plug.SSL.init(
         host: {__MODULE__, :authority, []},
         exclude: [hosts: ["localhost", "127.0.0.1"]]
       )

  @impl true
  def init(opts), do: opts

  @doc """
  The host of the HTTPS redirect: the endpoint's host, with its port when
  the endpoint URL is https on a port other than 443 (`Plug.SSL` only
  takes a host).
  """
  @spec authority() :: String.t()
  def authority do
    case HelmsmanWeb.Endpoint.struct_url() do
      %URI{scheme: "https", host: host, port: port} when port not in [nil, 443] ->
        "#{host}:#{port}"

      _ ->
        HelmsmanWeb.Endpoint.host()
    end
  end

  @impl true
  def call(conn, _opts) do
    if Application.get_env(:helmsman, :force_ssl, false) == true do
      Plug.SSL.call(conn, @ssl)
    else
      conn
    end
  end
end
