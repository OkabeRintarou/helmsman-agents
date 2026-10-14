defmodule HelmsmanDaemon.CLITest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  import HelmsmanDaemon.ServiceCase
  alias HelmsmanDaemon.{CLI, FakeServiceManager}

  defp code(args, opts \\ []) do
    capture_io(fn -> send(self(), {:code, CLI.run(args, opts)}) end)
    assert_received {:code, code}
    code
  end

  test "runtimes shows detection and workspaces without tokens" do
    Credentials.write(credentials())
    output = capture_io(fn -> assert CLI.run(["runtimes"]) == 0 end)
    assert output =~ "claude: 1.0.0 available"
    assert output =~ "bos"
    refute output =~ credentials().token
  end

  test "usage errors exit 2" do
    for args <- [
          ["unknown"],
          ["runtimes", "--force"],
          ["daemon", "start", "--bad"],
          ["daemon", "start", "--service"],
          ["daemon", "status", "--follow"],
          ["daemon", "logs", "-n", "0"],
          ["daemon", "stop", "--json"]
        ] do
      assert code(args) == 2, inspect(args)
    end
  end

  test "usage lists every command" do
    output = capture_io(fn -> assert CLI.run(["help"]) == 2 end)

    for command <-
          ~w(login logout runtimes repos) ++
            ["daemon start", "daemon stop", "daemon restart", "daemon status"] ++
            ["daemon logs", "--version"] do
      assert output =~ "helmsman #{command}"
    end
  end

  test "daemon start: mix refuses 2, no adapters 5, not logged in 1" do
    assert code(["daemon", "start"], adapters: []) == 2
    assert code(["daemon", "start", "--foreground"], adapters: []) == 5
    assert code(["daemon", "start"], adapters: [], standalone?: true, binary: "/b") == 5
    assert code(["daemon", "start", "--foreground"]) == 1
  end

  describe "background service commands" do
    setup do
      default_home!()
      {:ok, fake} = FakeServiceManager.start_link(:systemd)
      %{fake: fake, opts: service_opts(fake, :linux)}
    end

    test "start 0 (and already running 0), unavailable 3", %{fake: fake, opts: opts} do
      Credentials.write(credentials())
      assert code(["daemon", "start"], opts) == 0
      assert code(["daemon", "start"], opts) == 0
      FakeServiceManager.update(fake, %{available: false})
      assert code(["daemon", "start"], opts) == 3
    end

    test "stop 0 installed or not", %{opts: opts} do
      assert code(["daemon", "stop"], opts) == 0
      Credentials.write(credentials())
      assert code(["daemon", "start"], opts) == 0
      assert code(["daemon", "stop"], opts) == 0
    end

    test "restart: not installed 3, mix 2, installed 0", %{opts: opts} do
      Credentials.write(credentials())
      assert code(["daemon", "restart"], opts) == 3
      assert code(["daemon", "start"], opts) == 0
      assert code(["daemon", "restart"], Keyword.put(opts, :standalone?, false)) == 2
      assert code(["daemon", "restart"], opts) == 0
    end

    test "status 0 connected, 1 not connected, 3 not running", %{opts: opts} do
      assert code(["daemon", "status"], opts) == 3
      Credentials.write(credentials())
      assert code(["daemon", "start"], opts) == 0
      write_status()
      assert code(["daemon", "status"], opts) == 0
      write_status(%{"connected" => false})
      assert code(["daemon", "status", "--json"], opts) == 1
      assert code(["daemon", "stop"], opts) == 0
      old = DateTime.utc_now() |> DateTime.add(-300) |> DateTime.to_iso8601()
      write_status(%{"updated_at" => old})
      assert code(["daemon", "status"], opts) == 3
    end

    test "logs 0", %{opts: opts} do
      assert code(["daemon", "logs", "-n", "5"], opts) == 0
    end
  end

  test "--version" do
    assert code(["--version"]) == 0
  end
end
