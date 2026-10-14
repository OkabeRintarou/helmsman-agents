defmodule HelmsmanDaemon.KeychainTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  alias HelmsmanDaemon.{Config, Login}
  alias HelmsmanDaemon.Keychain.Security

  @service "dev.helmsman.daemon"
  @fake Path.expand("../support/fake_security/security", __DIR__)

  defp use_keychain(keychain) do
    Application.put_env(:helmsman_daemon, :credentials_store, :keychain)
    Application.put_env(:helmsman_daemon, :keychain, keychain)

    on_exit(fn ->
      Application.put_env(:helmsman_daemon, :credentials_store, :file)
      Application.delete_env(:helmsman_daemon, :keychain)
    end)
  end

  describe "configuration" do
    test "store defaults to keychain on macOS and file elsewhere" do
      assert Config.credentials_store(platform: :macos) == {:ok, :keychain}
      assert Config.credentials_store(platform: :linux) == {:ok, :file}

      File.write!(Path.join(Paths.home(), "config.toml"), "[credentials]\nstore = \"file\"\n")
      assert Config.credentials_store(platform: :macos) == {:ok, :file}
      assert {:ok, %{credentials_store: :file}} = Config.load(platform: :macos)
    end

    test "keychain on a non-macOS platform is an invalid configuration" do
      File.write!(Path.join(Paths.home(), "config.toml"), "[credentials]\nstore = \"keychain\"\n")
      assert Config.load(platform: :linux) == {:error, :invalid_config}
      assert Config.credentials_store(platform: :linux) == {:error, :invalid_config}
      assert Config.credentials_store(platform: :macos) == {:ok, :keychain}

      File.write!(Path.join(Paths.home(), "config.toml"), "[credentials]\nstore = \"vault\"\n")
      assert Config.load(platform: :macos) == {:error, :invalid_config}
    end
  end

  describe "security with a fake that records argv" do
    setup %{tmp_dir: dir} do
      fake_dir = Path.join(dir, "fake-security")
      File.mkdir_p!(fake_dir)
      previous = System.get_env("FAKE_SECURITY_DIR")
      System.put_env("FAKE_SECURITY_DIR", fake_dir)

      on_exit(fn ->
        if previous,
          do: System.put_env("FAKE_SECURITY_DIR", previous),
          else: System.delete_env("FAKE_SECURITY_DIR")
      end)

      %{fake_dir: fake_dir, opts: [security: @fake]}
    end

    test "add, find, delete and the three kinds of read result", %{fake_dir: fake_dir, opts: opts} do
      assert :ok = Security.add(@service, "https://hm.test 1 abcd", "hmd_secret_one", opts)
      assert {:ok, "hmd_secret_one"} = Security.find(@service, "https://hm.test 1 abcd", opts)
      assert {:error, :not_found} = Security.find(@service, "https://hm.test 1 other", opts)

      File.write!(Path.join(fake_dir, "locked"), "")
      assert {:error, :locked} = Security.find(@service, "https://hm.test 1 abcd", opts)
      assert {:error, :locked} = Security.delete(@service, "https://hm.test 1 abcd", opts)
      File.rm!(Path.join(fake_dir, "locked"))

      assert :ok = Security.delete(@service, "https://hm.test 1 abcd", opts)
      assert {:error, :not_found} = Security.delete(@service, "https://hm.test 1 abcd", opts)
      assert {:error, :unsupported_characters} = Security.add(@service, "a\"b", "hmd_x", opts)
      refute File.read!(Path.join(fake_dir, "argv.log")) =~ "hmd_"
    end

    test "login, rotation, migration and logout never put a token in any argv", %{
      fake_dir: fake_dir,
      opts: opts
    } do
      old = %{credentials() | token: "hmd_first_secret"}
      assert :ok = Credentials.write(old, store: :file)
      use_keychain({Security, opts})

      # Migration of the plaintext file.
      assert {:ok, %{token: "hmd_first_secret"}} = Credentials.read()
      refute File.read!(Paths.credentials()) =~ "hmd_"

      # Rotation.
      assert :ok = Credentials.write(%{old | token: "hmd_second_secret"})
      assert {:ok, %{token: "hmd_second_secret"}} = Credentials.read()
      assert [_] = File.ls!(Path.join(fake_dir, "items"))

      # Login --force.
      alias HelmsmanProtocol.DeviceAuth
      code_path = DeviceAuth.code_path()
      token_path = DeviceAuth.token_path()

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          ^code_path ->
            Req.Test.json(conn, %{
              device_code: "d",
              user_code: "ABCD-EFGH",
              verification_uri: "https://hm.test/verify",
              verification_uri_complete: "https://hm.test/verify?c=1",
              expires_in: 900,
              interval: 1
            })

          ^token_path ->
            Req.Test.json(conn, %{token: "hmd_third_secret", daemon_id: 9, workspaces: []})

          _logout ->
            Req.Test.json(conn, %{})
        end
      end)

      req = [req_options: [plug: {Req.Test, __MODULE__}], sleep: fn _ -> :ok end]

      output =
        capture_io(fn -> assert Login.login("https://hm.test", [force: true] ++ req) == 0 end)

      refute output =~ "hmd_"
      assert {:ok, %{token: "hmd_third_secret", daemon_id: 9}} = Credentials.read()

      # Logout deletes the items and the file.
      capture_io(fn -> assert Login.logout(req) == 0 end)
      refute File.exists?(Paths.credentials())
      assert File.ls!(Path.join(fake_dir, "items")) == []

      argv = File.read!(Path.join(fake_dir, "argv.log"))
      assert argv =~ "-i"
      assert argv =~ "find-generic-password -s dev.helmsman.daemon -a https://hm.test 9 "
      refute argv =~ "hmd_"
    end

    test "a locked keychain stops the daemon start with the store hint", %{
      fake_dir: fake_dir,
      opts: opts
    } do
      use_keychain({Security, opts})
      assert :ok = Credentials.write(credentials())
      File.write!(Path.join(fake_dir, "locked"), "")

      assert {:error, {:keychain, :locked}} = Credentials.read()

      output =
        capture_io(fn ->
          assert HelmsmanDaemon.CLI.run(["daemon", "start", "--foreground"]) == 1
        end)

      assert output =~ "the login keychain is locked"
      assert output =~ ~s([credentials] store = "file")
    end
  end

  describe "a temporary macOS keychain" do
    @describetag :macos

    setup %{tmp_dir: dir} do
      keychain = Path.join(dir, "test.keychain-db")
      {_, 0} = System.cmd("security", ["create-keychain", "-p", "test-password", keychain])
      {_, 0} = System.cmd("security", ["set-keychain-settings", keychain])
      {_, 0} = System.cmd("security", ["unlock-keychain", "-p", "test-password", keychain])
      on_exit(fn -> System.cmd("security", ["delete-keychain", keychain]) end)
      use_keychain({Security, keychain: keychain})
      %{keychain: keychain}
    end

    test "login writes the keychain item and a file without the token; logout deletes both", %{
      keychain: keychain
    } do
      assert :ok = Credentials.write(credentials())
      refute File.read!(Paths.credentials()) =~ "hmd_"
      assert {:ok, read} = Credentials.read()
      assert read.token == credentials().token

      %{"token_ref" => ref} = Paths.credentials() |> File.read!() |> Jason.decode!()
      account = "http://localhost:49999 1 #{ref}"
      assert {:ok, token} = Security.find(@service, account, keychain: keychain)
      assert token == credentials().token

      assert :ok = Credentials.delete()
      refute File.exists?(Paths.credentials())
      assert {:error, :not_found} = Security.find(@service, account, keychain: keychain)
    end

    test "migration of a plaintext credentials file", %{keychain: keychain} do
      assert :ok = Credentials.write(credentials(), store: :file)
      assert {:ok, %{token: token}} = Credentials.read()
      assert token == credentials().token
      %{"token_ref" => ref} = Paths.credentials() |> File.read!() |> Jason.decode!()
      refute File.read!(Paths.credentials()) =~ "hmd_"

      assert {:ok, ^token} =
               Security.find(@service, "http://localhost:49999 1 #{ref}", keychain: keychain)
    end

    test "rotation creates a new generation and deletes the old one", %{keychain: keychain} do
      assert :ok = Credentials.write(credentials())
      %{"token_ref" => old_ref} = Paths.credentials() |> File.read!() |> Jason.decode!()

      assert :ok = Credentials.write(%{credentials() | token: "hmd_rotated_token"})
      assert {:ok, %{token: "hmd_rotated_token"}} = Credentials.read()

      assert {:error, :not_found} =
               Security.find(@service, "http://localhost:49999 1 #{old_ref}", keychain: keychain)
    end

    test "a locked keychain is reported, not treated as missing", %{keychain: keychain} do
      assert :ok = Credentials.write(credentials())
      {_, 0} = System.cmd("security", ["lock-keychain", keychain])

      log = capture_log(fn -> assert {:error, {:keychain, _reason}} = Credentials.read() end)
      refute log =~ "hmd_"
      assert File.read!(Paths.credentials()) =~ "token_ref"
    end
  end
end
