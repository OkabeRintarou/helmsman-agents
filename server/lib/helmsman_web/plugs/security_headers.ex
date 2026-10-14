defmodule HelmsmanWeb.Plugs.SecurityHeaders do
  @moduledoc """
  The browser pipeline's security headers (`add-release-distribution`
  decision 7), after `put_secure_browser_headers`: a Content Security
  Policy, `referrer-policy` and `permissions-policy`. API, MCP and webhook
  responses never pass through it.

  Scripts and connections are limited to this site (the LiveView socket's
  `ws:` / `wss:` URL is listed besides `'self'`), the page cannot be
  framed and forms post only here and to GitHub (the App manifest flow).
  Inline styles stay allowed (Mermaid's SVG, LiveView's JS commands);
  inline scripts are not.

  With `nonce: true` a fresh nonce is assigned as `:csp_nonce` and allowed
  in `script-src` (LiveDashboard's inline bootstrap script).
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: Keyword.validate!(opts, nonce: false)

  @impl true
  def call(conn, opts) do
    {conn, script_src} =
      if opts[:nonce] do
        nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()
        {assign(conn, :csp_nonce, nonce), "'self' 'nonce-#{nonce}'"}
      else
        {conn, "'self'"}
      end

    conn
    |> put_resp_header("content-security-policy", policy(script_src))
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("permissions-policy", "camera=(), microphone=(), geolocation=()")
  end

  defp policy(script_src) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src #{script_src}",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: https:",
        "font-src 'self' data:",
        "connect-src 'self' #{socket_origin()}",
        "frame-ancestors 'none'",
        "base-uri 'self'",
        "form-action 'self' https://github.com",
        "object-src 'none'"
      ],
      "; "
    )
  end

  # The public URL's origin with the WebSocket scheme.
  defp socket_origin do
    %URI{scheme: scheme, host: host, port: port} = HelmsmanWeb.Endpoint.struct_url()
    ws = if scheme == "https", do: "wss", else: "ws"

    if port in [nil, URI.default_port(scheme)],
      do: "#{ws}://#{host}",
      else: "#{ws}://#{host}:#{port}"
  end
end
