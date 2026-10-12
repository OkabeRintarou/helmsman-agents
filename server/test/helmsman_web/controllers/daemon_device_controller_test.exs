defmodule HelmsmanWeb.DaemonDeviceControllerTest do
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RateLimitHelpers, only: [unique_ip: 0]
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.Daemons
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.Repo
  alias HelmsmanProtocol.{DeviceAuth, ErrorReply}
  alias HelmsmanProtocol.DeviceAuth.{CodeRequest, CodeResponse, TokenRequest}

  # Every request comes from its own address: /daemon/device/code is limited per IP.
  defp client(conn), do: %{conn | remote_ip: unique_ip()}

  defp machine(attrs \\ %{}) do
    Map.merge(
      %{
        machine_id: "machine-#{System.unique_integer([:positive])}",
        name: "alice-laptop",
        os: "linux",
        arch: "x86_64",
        daemon_version: "0.1.0"
      },
      attrs
    )
  end

  defp code_request(attrs \\ %{}) do
    {:ok, request} =
      CodeRequest.new(
        Map.merge(%{protocol: HelmsmanProtocol.version(), machine: machine()}, attrs)
      )

    CodeRequest.to_wire(request)
  end

  defp token_request(device_code) do
    {:ok, request} = TokenRequest.new(%{device_code: device_code})
    TokenRequest.to_wire(request)
  end

  defp post_json(conn, path, body), do: conn |> client() |> send_json(path, body)

  defp send_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp request_code(conn, body \\ code_request()) do
    conn = post_json(conn, DeviceAuth.code_path(), body)
    assert {:ok, %CodeResponse{} = code} = CodeResponse.from_wire(json_response(conn, 200))
    code
  end

  defp poll(conn, device_code) do
    conn = post_json(conn, DeviceAuth.token_path(), token_request(device_code))
    DeviceAuth.decode_token_reply(conn.status, Jason.decode!(conn.resp_body))
  end

  setup do
    alice = user_fixture()
    acme = workspace_fixture(alice, %{slug: "acme#{System.unique_integer([:positive])}"})
    %{alice: alice, acme: acme, scope: Scope.for_user(alice)}
  end

  describe "POST /daemon/device/code" do
    test "issues a code with the verification addresses and polling interval", %{conn: conn} do
      code = request_code(conn)

      url = HelmsmanWeb.Endpoint.url()
      assert code.verification_uri == url <> "/device"
      assert code.verification_uri_complete == url <> "/device?code=" <> code.user_code
      assert DeviceAuth.valid_user_code?(code.user_code)
      assert code.expires_in == 600
      assert code.interval == 5
    end

    test "an incompatible protocol is 426 with versions and the upgrade address", %{conn: conn} do
      # Spec 「协议不兼容」: protocol 0.
      body = Map.put(code_request(), "protocol", 0)
      conn = post_json(conn, DeviceAuth.code_path(), body)

      assert conn.status == 426

      assert {:error, :unsupported_protocol} =
               DeviceAuth.decode_token_reply(426, json_response(conn, 426))

      assert {:ok, reply} = ErrorReply.from_wire(json_response(conn, 426))
      assert reply.reason == :unsupported_protocol
      assert reply.server_version == HelmsmanProtocol.version()
      assert reply.min_version == HelmsmanProtocol.min_version()
      assert reply.upgrade_url == HelmsmanWeb.DaemonDeviceController.upgrade_url()
    end

    test "a protocol newer than the server is 426", %{conn: conn} do
      body = Map.put(code_request(), "protocol", HelmsmanProtocol.version() + 1)
      conn = post_json(conn, DeviceAuth.code_path(), body)

      assert {:ok, %ErrorReply{reason: :unsupported_protocol}} =
               ErrorReply.from_wire(json_response(conn, 426))
    end

    test "an invalid payload is 400 invalid_payload", %{conn: conn} do
      for body <- [%{}, %{"protocol" => 1}, Map.put(code_request(), "machine", "x")] do
        conn = post_json(conn, DeviceAuth.code_path(), body)

        assert {:ok, %ErrorReply{reason: :invalid_payload}} =
                 ErrorReply.from_wire(json_response(conn, 400))
      end
    end

    test "more than 10 requests a minute from one address are 429", %{conn: conn} do
      conn = client(conn)

      for _ <- 1..10 do
        assert conn
               |> recycle_ip()
               |> send_json(DeviceAuth.code_path(), code_request())
               |> json_response(200)
      end

      assert conn
             |> recycle_ip()
             |> send_json(DeviceAuth.code_path(), code_request())
             |> json_response(429)

      # Another address is not affected.
      assert post_json(build_conn(), DeviceAuth.code_path(), code_request()) |> json_response(200)
    end
  end

  # A fresh conn from the same client address.
  defp recycle_ip(conn), do: %{build_conn() | remote_ip: conn.remote_ip}

  describe "POST /daemon/device/token" do
    test "the full login (spec 完整登录)", %{conn: conn, scope: scope, acme: acme, alice: alice} do
      code = request_code(conn)

      assert poll(conn, code.device_code) == {:pending, :authorization_pending}

      typed = code.user_code |> String.replace("-", "") |> String.downcase()
      assert {:ok, _} = Daemons.approve_device(scope, typed, [acme.id])

      assert {:ok, response} = poll(conn, code.device_code)
      assert "hmd_" <> _ = response.token
      assert [%{id: id, slug: slug}] = response.workspaces
      assert {id, slug} == {acme.id, acme.slug}

      daemon = Repo.get!(Daemon, response.daemon_id)
      assert daemon.user_id == alice.id
      assert daemon.name == "alice-laptop"
      assert {:ok, %Daemon{id: daemon_id}} = Daemons.authenticate(response.token)
      assert daemon_id == response.daemon_id

      assert poll(conn, code.device_code) == {:error, :expired_token}
    end

    test "a denied code is access_denied", %{conn: conn, scope: scope} do
      code = request_code(conn)
      assert {:ok, _} = Daemons.deny_device(scope, code.user_code)
      assert poll(conn, code.device_code) == {:error, :access_denied}
    end

    test "an unknown code is expired_token", %{conn: conn} do
      assert poll(conn, "no-such-code") == {:error, :expired_token}
    end

    test "an invalid payload is 400 expired_token and nothing more", %{conn: conn} do
      for body <- [%{}, %{"device_code" => 1}] do
        conn = post_json(conn, DeviceAuth.token_path(), body)
        assert json_response(conn, 400) == %{"error" => "expired_token"}
      end
    end
  end

  describe "POST /daemon/logout" do
    test "revokes the token's daemon", %{conn: conn, alice: alice, acme: acme} do
      {daemon, token} = daemon_fixture(alice, %{workspace_ids: [acme.id]})
      runtime = runtime_fixture(acme, daemon)

      conn =
        conn
        |> client()
        |> put_req_header(HelmsmanProtocol.token_header(), token)
        |> send_json(DeviceAuth.logout_path(), %{})

      assert json_response(conn, 200) == %{}

      daemon = Repo.get!(Daemon, daemon.id)
      assert daemon.revoked_at
      assert daemon.auth_epoch == 2
      assert Repo.get!(Runtime, runtime.id).status == "offline"
      assert Daemons.authenticate(token) == {:error, :unauthorized}
    end

    test "an invalid, revoked or missing token is 401", %{conn: conn, alice: alice, scope: scope} do
      {daemon, token} = daemon_fixture(alice)
      {:ok, _} = Daemons.revoke(scope, daemon.id)

      for header <- [token, "hmd_" <> String.duplicate("a", 52), "nope"] do
        conn =
          conn
          |> client()
          |> put_req_header(HelmsmanProtocol.token_header(), header)
          |> send_json(DeviceAuth.logout_path(), %{})

        assert json_response(conn, 401)
      end

      assert conn |> client() |> send_json(DeviceAuth.logout_path(), %{}) |> json_response(401)
    end

    test "the token in the body or query string is not accepted", %{conn: conn, alice: alice} do
      {daemon, token} = daemon_fixture(alice)

      assert conn
             |> client()
             |> send_json(DeviceAuth.logout_path(), %{"token" => token})
             |> json_response(401)

      assert conn
             |> client()
             |> send_json(DeviceAuth.logout_path() <> "?x-helmsman-token=" <> token, %{})
             |> json_response(401)

      assert is_nil(Repo.get!(Daemon, daemon.id).revoked_at)
    end
  end
end
