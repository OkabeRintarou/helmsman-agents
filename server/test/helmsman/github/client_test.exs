defmodule Helmsman.GitHub.ClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Helmsman.GitHubFixtures

  alias Helmsman.GitHub.AppConfig
  alias Helmsman.GitHub.Client
  alias Helmsman.GitHub.JWT
  alias Helmsman.GitHub.Tokens

  describe "JWT.app_token/2" do
    test "is RS256, signed with the App key, iss/iat/exp per design" do
      {:ok, config} = AppConfig.current()
      now = 1_800_000_000
      token = JWT.app_token(config, now)

      public = private_key_pem() |> JOSE.JWK.from_pem() |> JOSE.JWK.to_public()

      assert {true, %JOSE.JWT{fields: claims}, %JOSE.JWS{alg: {_, :RS256}}} =
               JOSE.JWT.verify_strict(public, ["RS256"], token)

      assert claims == %{"iss" => app_id(), "iat" => now - 60, "exp" => now + 540}
      assert claims["exp"] - claims["iat"] <= 600
    end
  end

  describe "paginate/2" do
    test "follows Link rel=next until the last page" do
      stub_github(fn conn ->
        page = String.to_integer(conn.query_params["page"] || "1")
        conn = Plug.Conn.fetch_query_params(conn)

        conn =
          if page < 3 do
            Plug.Conn.put_resp_header(
              conn,
              "link",
              ~s(<https://api.github.com/items?per_page=100&page=#{page + 1}>; rel="next", ) <>
                ~s(<https://api.github.com/items?per_page=100&page=3>; rel="last")
            )
          else
            conn
          end

        Req.Test.json(conn, %{"items" => [%{"page" => page}]})
      end)

      assert {:ok, [%{"page" => 1}, %{"page" => 2}, %{"page" => 3}]} =
               Client.paginate("/items", key: "items")
    end

    test "stops at :max" do
      stub_github(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("link", ~s(<https://api.github.com/b?page=2>; rel="next"))
        |> Req.Test.json(Enum.map(1..100, &%{"n" => &1}))
      end)

      assert {:ok, items} = Client.paginate("/b", max: 150)
      assert length(items) == 150
    end
  end

  describe "error normalization" do
    test "403 with x-ratelimit-remaining 0 → rate_limited at the reset time" do
      reset = DateTime.utc_now(:second) |> DateTime.add(180)

      stub_github(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header(
          "x-ratelimit-reset",
          Integer.to_string(DateTime.to_unix(reset))
        )
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"message" => "API rate limit exceeded"})
      end)

      assert Client.request(:get, "/x") == {:error, {:rate_limited, reset}}
    end

    test "429 with retry-after → rate_limited after that many seconds" do
      stub_github(fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "30") |> Plug.Conn.send_resp(429, "")
      end)

      assert {:error, {:rate_limited, at}} = Client.request(:get, "/x")
      assert DateTime.diff(at, DateTime.utc_now()) in 28..31
    end

    test "403 without rate limit headers is a plain error" do
      stub_github(&Plug.Conn.send_resp(&1, 403, ""))
      assert Client.request(:get, "/x") == {:error, {:github_error, 403}}
    end

    test "5xx and transport errors → github_unavailable" do
      stub_github(&Plug.Conn.send_resp(&1, 502, ""))
      assert {:error, {:github_unavailable, _}} = Client.request(:get, "/x")

      stub_github(&Req.Test.transport_error(&1, :econnrefused))
      assert {:error, {:github_unavailable, :econnrefused}} = Client.request(:get, "/x")
    end

    test "404 → not_found" do
      stub_github(&not_found/1)
      assert Client.request(:get, "/x") == {:error, :not_found}
    end
  end

  test "tokens and the private key never reach the logs" do
    stub_github(fn conn ->
      case conn.request_path do
        "/app/installations/" <> _ -> token_response(conn, "ghs_secret_token_value")
        _ -> Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    log =
      capture_log([level: :debug], fn ->
        {:ok, %{token: token}} = Tokens.get(unique_github_id())
        Client.request(:get, "/repos/a/b", auth: {:token, token})
        Client.request(:get, "/app", auth: :app)
      end)

    refute log =~ "ghs_secret_token_value"
    refute log =~ "PRIVATE KEY"
    refute log =~ "Bearer"
  end
end
