defmodule HelmsmanWeb.RemoteIpTest do
  # server-release "运行时配置": trusted reverse proxies (X-Forwarded-For /
  # X-Forwarded-Proto), the rate limit's client address, the public URL's
  # scheme. Changes the trusted proxies, the rate limits and force_ssl.
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.RateLimitHelpers
  import Helmsman.RuntimeConfigHelpers
  import Phoenix.LiveViewTest

  alias Helmsman.RateLimit
  alias HelmsmanWeb.Plugs.TrustedProxies

  @minute :timer.minutes(1)

  setup do
    put_rate_limits()

    for key <- [:trusted_proxies, :force_ssl, :secure_cookies] do
      previous = Application.get_env(:helmsman, key)
      on_exit(fn -> Application.put_env(:helmsman, key, previous) end)
    end

    %{user: set_password(user_fixture())}
  end

  defp trust(cidrs), do: Application.put_env(:helmsman, :trusted_proxies, cidrs)

  defp hits(bucket, ip) when is_tuple(ip), do: hits(bucket, RateLimit.ip_key(ip))
  defp hits(bucket, ip), do: RateLimit.get({bucket, ip}, @minute)

  # A request whose TCP peer is `ip` (conn.remote_ip and the socket's peer data).
  defp from(conn, ip) do
    %{conn | remote_ip: ip}
    |> Plug.Test.put_peer_data(%{address: ip, port: 40_000, ssl_cert: nil})
  end

  defp log_in(conn, user) do
    post(conn, ~p"/users/log-in", %{
      "user" => %{"email" => user.email, "password" => valid_user_password()}
    })
  end

  defp request_magic_link(conn, user) do
    {:ok, lv, _html} = live(conn, ~p"/users/log-in")

    lv
    |> form("#login_form_magic", user: %{email: user.email})
    |> render_submit()
  end

  # A public address no other test uses.
  defp public_ip do
    n = System.unique_integer([:positive])
    {198, 18, rem(div(n, 256), 256), rem(n, 256)}
  end

  describe "without trusted proxies" do
    test "forged X-Forwarded-For (scenario): the IP bucket is the connection's address",
         %{conn: conn, user: user} do
      peer = unique_ip()
      forged_before = hits(:password_ip, "1.2.3.4")

      conn =
        conn
        |> from(peer)
        |> put_req_header("x-forwarded-for", "1.2.3.4")
        |> put_req_header("x-forwarded-proto", "https")
        |> log_in(user)

      assert redirected_to(conn) == ~p"/"
      assert conn.remote_ip == peer
      assert conn.scheme == :http
      assert hits(:password_ip, peer) == 1
      assert hits(:password_ip, "1.2.3.4") == forged_before
    end

    test "forged X-Forwarded-For on the LiveView login: the magic link bucket is the peer's",
         %{conn: conn, user: user} do
      peer = unique_ip()
      forged = public_ip()

      conn
      |> from(peer)
      |> put_req_header("x-forwarded-for", RateLimit.ip_key(forged))
      |> request_magic_link(user)

      assert hits(:magic_link_ip, peer) == 1
      assert hits(:magic_link_ip, forged) == 0
    end

    test "X-Forwarded-Proto does not avoid the HTTPS redirect", %{conn: conn} do
      Application.put_env(:helmsman, :force_ssl, true)

      conn =
        %{conn | host: "hm.example.com"}
        |> from(unique_ip())
        |> put_req_header("x-forwarded-proto", "https")
        |> get(~p"/users/log-in")

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["https://localhost/users/log-in"]
    end
  end

  describe "behind a trusted proxy 10.0.0.0/8" do
    setup do
      trust(["10.0.0.0/8"])
    end

    test "(scenario) the client address is X-Forwarded-For's; the scheme https",
         %{conn: conn, user: user} do
      client = public_ip()
      Application.put_env(:helmsman, :force_ssl, true)

      conn =
        %{conn | host: "hm.example.com"}
        |> from({10, 0, 0, 5})
        |> put_req_header("x-forwarded-for", RateLimit.ip_key(client))
        |> put_req_header("x-forwarded-proto", "https")
        |> log_in(user)

      # Not redirected to HTTPS: the request is https.
      assert redirected_to(conn) == ~p"/"
      assert conn.remote_ip == client
      assert conn.scheme == :https
      assert Plug.Conn.request_url(conn) =~ ~r"^https://hm\.example\.com/"
      assert hits(:password_ip, client) == 1
      assert hits(:password_ip, {10, 0, 0, 5}) == 0

      # The session cookie is Secure on an https request.
      assert [cookie] =
               conn |> get_resp_header("set-cookie") |> Enum.filter(&(&1 =~ "_helmsman_key="))

      assert cookie =~ ~r/; secure/i
    end

    test "203.0.113.9 as in the scenario", %{conn: conn} do
      conn =
        conn
        |> from({10, 0, 0, 5})
        |> put_req_header("x-forwarded-for", "203.0.113.9")
        |> put_req_header("x-forwarded-proto", "https")
        |> get(~p"/users/log-in")

      assert conn.remote_ip == {203, 0, 113, 9}
      assert conn.scheme == :https
    end

    test "the LiveView login takes the client address from the proxy's header",
         %{conn: conn, user: user} do
      client = public_ip()

      conn
      |> from({10, 0, 0, 5})
      |> put_req_header("x-forwarded-for", RateLimit.ip_key(client))
      |> request_magic_link(user)

      assert hits(:magic_link_ip, client) == 1
      assert hits(:magic_link_ip, {10, 0, 0, 5}) == 0
    end

    test "a peer outside the trusted ranges cannot forge its address or scheme", %{conn: conn} do
      peer = {192, 0, 2, 10}

      conn =
        conn
        |> from(peer)
        |> put_req_header("x-forwarded-for", "203.0.113.9")
        |> put_req_header("x-forwarded-proto", "https")
        |> get(~p"/users/log-in")

      assert conn.remote_ip == peer
      assert conn.scheme == :http
    end

    test "the rightmost address that is not a trusted proxy is the client", %{conn: conn} do
      cases = [
        {"1.2.3.4, 198.51.100.7", {198, 51, 100, 7}},
        {"198.51.100.1, 10.0.0.9", {198, 51, 100, 1}},
        # A private client address on the proxy's side is kept.
        {"192.168.1.20", {192, 168, 1, 20}},
        # Only trusted hops: the peer.
        {"10.1.2.3", {10, 0, 0, 5}}
      ]

      for {header, expected} <- cases do
        conn =
          conn
          |> recycle()
          |> from({10, 0, 0, 5})
          |> put_req_header("x-forwarded-for", header)
          |> get(~p"/users/log-in")

        assert conn.remote_ip == expected, "#{header}: #{inspect(conn.remote_ip)}"
      end
    end

    test "an IPv4 peer on the dual-stack listener (::ffff:10.0.0.5) is trusted", %{conn: conn} do
      conn =
        conn
        |> from({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0005})
        |> put_req_header("x-forwarded-for", "203.0.113.9")
        |> get(~p"/users/log-in")

      assert conn.remote_ip == {203, 0, 113, 9}
    end

    test "without X-Forwarded-Proto a plain HTTP request from the proxy is redirected",
         %{conn: conn} do
      Application.put_env(:helmsman, :force_ssl, true)

      conn =
        %{conn | host: "hm.example.com"}
        |> from({10, 0, 0, 5})
        |> get(~p"/users/log-in")

      assert conn.status == 301
    end
  end

  describe "behind a narrow trusted proxy range" do
    # The real client is a private neighbour of the proxy; it prepends a
    # forged public hop, the proxy appends the real address.
    test "a single-address proxy: the adjacent private client is not skipped",
         %{conn: conn, user: user} do
      trust(["10.0.0.5/32"])
      client = {10, 0, 0, 6}
      forged = public_ip()
      forged_before = hits(:password_ip, forged)
      client_before = hits(:password_ip, client)
      header = "#{RateLimit.ip_key(forged)}, 10.0.0.6"

      assert TrustedProxies.client_ip({10, 0, 0, 5}, [
               {"x-forwarded-for", header}
             ]) == client

      conn =
        conn
        |> from({10, 0, 0, 5})
        |> put_req_header("x-forwarded-for", header)
        |> log_in(user)

      assert conn.remote_ip == client
      assert hits(:password_ip, client) == client_before + 1
      assert hits(:password_ip, forged) == forged_before
    end

    test "a /24 proxy range: the rightmost address outside it is the client", %{conn: conn} do
      trust(["192.168.1.0/24"])

      cases = [
        {"203.0.113.9, 192.168.2.7", {192, 168, 2, 7}},
        {"203.0.113.9, 192.168.2.7, 192.168.1.3", {192, 168, 2, 7}},
        {"203.0.113.9, 127.0.0.1", {127, 0, 0, 1}},
        # Only trusted hops: the peer.
        {"192.168.1.3, 192.168.1.4", {192, 168, 1, 10}}
      ]

      for {header, expected} <- cases do
        conn =
          conn
          |> recycle()
          |> from({192, 168, 1, 10})
          |> put_req_header("x-forwarded-for", header)
          |> get(~p"/users/log-in")

        assert conn.remote_ip == expected, "#{header}: #{inspect(conn.remote_ip)}"
      end
    end

    test "an IPv6 private range: the adjacent client is not skipped", %{conn: conn} do
      trust(["fd00::5/128"])

      conn =
        conn
        |> from({0xFD00, 0, 0, 0, 0, 0, 0, 5})
        |> put_req_header("x-forwarded-for", "2001:db8::9, fd00::6")
        |> get(~p"/users/log-in")

      assert conn.remote_ip == {0xFD00, 0, 0, 0, 0, 0, 0, 6}
    end

    test "the LiveView login uses the same client address", %{conn: conn, user: user} do
      trust(["10.0.0.5/32"])
      client = {10, 0, 0, 7}
      forged = public_ip()
      client_before = hits(:magic_link_ip, client)

      conn
      |> from({10, 0, 0, 5})
      |> put_req_header("x-forwarded-for", "#{RateLimit.ip_key(forged)}, 10.0.0.7")
      |> request_magic_link(user)

      assert hits(:magic_link_ip, client) == client_before + 1
      assert hits(:magic_link_ip, forged) == 0
    end

    test "an untrusted private neighbour cannot forge through its own header", %{conn: conn} do
      trust(["10.0.0.5/32"])

      conn =
        conn
        |> from({10, 0, 0, 6})
        |> put_req_header("x-forwarded-for", "203.0.113.9")
        |> get(~p"/users/log-in")

      assert conn.remote_ip == {10, 0, 0, 6}
    end
  end

  describe "https on a port other than 443" do
    setup do
      previous = Application.fetch_env!(:helmsman, HelmsmanWeb.Endpoint)
      config = Keyword.put(previous, :url, host: "hm.example.com", scheme: "https", port: 8443)
      Application.put_env(:helmsman, HelmsmanWeb.Endpoint, config)
      HelmsmanWeb.Endpoint.config_change(%{HelmsmanWeb.Endpoint => config}, [])

      on_exit(fn ->
        Application.put_env(:helmsman, HelmsmanWeb.Endpoint, previous)
        HelmsmanWeb.Endpoint.config_change(%{HelmsmanWeb.Endpoint => previous}, [])
      end)

      Application.put_env(:helmsman, :force_ssl, true)
      trust(["10.0.0.0/8"])
    end

    test "redirects keep the port, the path and the query", %{conn: conn} do
      assert HelmsmanWeb.Endpoint.url() == "https://hm.example.com:8443"

      for {method, path, status} <- [
            {:get, "/users/log-in?q=1", 301},
            {:head, "/users/log-in", 301},
            {:post, "/users/log-in", 307},
            {:get, "/robots.txt", 301},
            {:get, "/assets/css/app.css", 301},
            {:get, "/downloads/daemon/linux-x64", 301}
          ] do
        conn =
          conn
          |> recycle()
          |> Map.put(:host, "hm.example.com")
          |> from(unique_ip())
          |> dispatch(@endpoint, method, path)

        assert conn.status == status, "#{method} #{path}"

        assert get_resp_header(conn, "location") == ["https://hm.example.com:8443#{path}"],
               "#{method} #{path}"
      end
    end

    test "a trusted proxy's x-forwarded-proto https is served with HSTS", %{conn: conn} do
      conn =
        conn
        |> Map.put(:host, "hm.example.com")
        |> from({10, 0, 0, 5})
        |> put_req_header("x-forwarded-proto", "https")
        |> get("/robots.txt")

      assert conn.status == 200
      assert get_resp_header(conn, "strict-transport-security") != []
    end

    test "the health check on localhost is not redirected", %{conn: conn} do
      conn = conn |> from({127, 0, 0, 1}) |> get("/healthz")
      assert conn.status == 200
    end
  end

  describe "static files with an https public URL" do
    # The test environment has no built assets: /assets/css/app.css shows the
    # redirect, robots.txt (in priv/static) the file being served.
    setup do
      Application.put_env(:helmsman, :force_ssl, true)
      trust(["10.0.0.0/8"])
    end

    test "over plain HTTP: 301 to https", %{conn: conn} do
      for path <- ["/assets/css/app.css", "/robots.txt"] do
        conn =
          conn |> recycle() |> Map.put(:host, "hm.example.com") |> from(unique_ip()) |> get(path)

        assert conn.status == 301, path
        assert get_resp_header(conn, "location") == ["https://localhost#{path}"]
      end
    end

    test "from a trusted proxy with x-forwarded-proto https: served", %{conn: conn} do
      via_proxy = fn conn ->
        conn
        |> Map.put(:host, "hm.example.com")
        |> from({10, 0, 0, 5})
        |> put_req_header("x-forwarded-proto", "https")
      end

      robots = conn |> via_proxy.() |> get("/robots.txt")
      assert robots.status == 200

      assert robots.resp_body ==
               File.read!(Application.app_dir(:helmsman, "priv/static/robots.txt"))

      assert get_resp_header(robots, "strict-transport-security") != []

      css = conn |> recycle() |> via_proxy.() |> get("/assets/css/app.css")
      refute css.status == 301
    end

    test "the same header from an untrusted peer is still redirected", %{conn: conn} do
      conn =
        conn
        |> Map.put(:host, "hm.example.com")
        |> from({192, 0, 2, 10})
        |> put_req_header("x-forwarded-proto", "https")
        |> get("/robots.txt")

      assert conn.status == 301
    end
  end

  describe "private network over HTTP (scenario)" do
    test "PHX_URL_SCHEME=http: no Secure cookie, no redirect, login works", %{
      conn: conn,
      user: user
    } do
      config =
        read_prod_runtime(
          prod_env(%{
            "PHX_URL_SCHEME" => "http",
            "PHX_URL_PORT" => "4000",
            "PHX_HOST" => "10.1.1.1"
          })
        )

      assert config[:helmsman][:secure_cookies] == false
      assert config[:helmsman][:force_ssl] == false
      assert config[:helmsman][:public_url] == "http://10.1.1.1:4000"

      Application.put_env(:helmsman, :secure_cookies, false)
      Application.put_env(:helmsman, :force_ssl, false)

      conn = conn |> from(unique_ip()) |> log_in(user)
      assert redirected_to(conn) == ~p"/"

      [cookie] =
        conn |> get_resp_header("set-cookie") |> Enum.filter(&(&1 =~ "_helmsman_key="))

      refute cookie =~ ~r/secure/i

      assert conn |> recycle() |> get(~p"/users/settings") |> html_response(200)
    end
  end
end
