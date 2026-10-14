defmodule HelmsmanDaemon.LoginTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  alias HelmsmanDaemon.Login

  setup do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/daemon/device/code" -> Req.Test.json(conn, code())
        "/daemon/device/token" -> Req.Test.json(conn, token())
      end
    end)

    %{opts: [req_options: [plug: {Req.Test, __MODULE__}], sleep: fn _ -> :ok end]}
  end

  defp code do
    %{
      device_code: "private_device_code",
      user_code: "ABCD-EFGH",
      verification_uri: "https://example.test/verify",
      verification_uri_complete: "https://example.test/verify?code=ABCD-EFGH",
      expires_in: 900,
      interval: 2
    }
  end

  defp token,
    do: %{
      token: "hmd_login_secret",
      daemon_id: 42,
      workspaces: [%{id: 1, slug: "bos", name: "Bosun"}]
    }

  test "pending and slowdown increase interval without exposing token", %{opts: opts} do
    Req.Test.expect(__MODULE__, 4, fn conn ->
      count = Process.get(:login_calls, 0)
      Process.put(:login_calls, count + 1)

      case count do
        0 -> Req.Test.json(conn, code())
        1 -> conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: "authorization_pending"})
        2 -> conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: "slow_down"})
        3 -> Req.Test.json(conn, token())
      end
    end)

    owner = self()

    output =
      capture_io(fn ->
        assert Login.login(
                 "https://example.test",
                 Keyword.put(opts, :sleep, &send(owner, {:sleep, &1}))
               ) == 0
      end)

    assert_receive {:sleep, 2_000}
    assert_receive {:sleep, 2_000}
    assert_receive {:sleep, 7_000}
    assert {:ok, %{token: "hmd_login_secret", daemon_id: 42}} = Credentials.read()
    assert output =~ "ABCD-EFGH"
    assert output =~ "bos"
    refute output =~ "hmd_login_secret"
    refute output =~ "private_device_code"
  end

  test "denied and expired do not write credentials", %{opts: opts} do
    for error <- ["access_denied", "expired_token"] do
      Req.Test.stub(__MODULE__, fn conn ->
        if conn.request_path == "/daemon/device/code",
          do: Req.Test.json(conn, code()),
          else: conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: error})
      end)

      capture_io(fn -> assert Login.login("https://example.test", opts) == 3 end)
      refute File.exists?(Paths.credentials())
    end
  end

  test "already logged in rejects and force overwrites", %{opts: opts} do
    Credentials.write(credentials())
    capture_io(fn -> assert Login.login("https://example.test", opts) == 3 end)
    assert {:ok, %{token: "hmd_private_daemon_token"}} = Credentials.read()

    capture_io(fn ->
      assert Login.login("https://example.test", Keyword.put(opts, :force, true)) == 0
    end)

    assert {:ok, %{token: "hmd_login_secret"}} = Credentials.read()
  end

  test "426 version incompatible exits 4", %{opts: opts} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(426) |> Req.Test.json(%{})
    end)

    output = capture_io(fn -> assert Login.login("https://example.test/", opts) == 4 end)
    assert output =~ "curl -fsSL https://example.test/install.sh | sh"
  end

  test "offline logout always deletes credentials", %{opts: opts} do
    Credentials.write(credentials())
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    output = capture_io(fn -> assert Login.logout(opts) == 0 end)
    assert output =~ "website"
    refute output =~ credentials().token
    refute File.exists?(Paths.credentials())
  end
end
