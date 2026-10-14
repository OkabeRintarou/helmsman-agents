defmodule HelmsmanDaemon.DetectorTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{Connection, Detector, Exec}
  alias HelmsmanProtocol.Messages

  defmodule Old do
    def provider, do: :codex
    def detect, do: {:ok, %{version: "1.9.0", models: []}}
    def min_version, do: Version.parse!("2.0.0")
  end

  defmodule Legacy do
    def provider, do: :codex
    def detect, do: {:ok, %{version: "2.0.0", models: []}}
    def min_version, do: Version.parse!("2.0.0")
  end

  defmodule Toggle do
    def provider, do: :claude

    def detect do
      if Process.whereis(:detector_toggle),
        do: {:ok, %{version: "2.0.0", models: ["test"], efforts: ["low", "high"]}},
        else: {:error, "missing"}
    end

    def min_version, do: Version.parse!("2.0.0")
  end

  defmodule WithVendor do
    alias HelmsmanDaemon.Adapters.Claude
    def provider, do: :claude
    def detect, do: {:ok, %{version: "2.1.0", models: []}}
    def min_version, do: Version.parse!("2.1.0")
    def vendor, do: Claude.vendor()
  end

  defmodule InvalidVendor do
    def provider, do: :cursor
    def detect, do: {:ok, %{version: "2.1.0", models: []}}
    def min_version, do: Version.parse!("2.1.0")
    def vendor, do: "https://private.example/SECRET"
  end

  defmodule RaisingVendor do
    def provider, do: :copilot
    def detect, do: {:ok, %{version: "2.1.0", models: []}}
    def min_version, do: Version.parse!("2.1.0")
    def vendor, do: raise("SECRET")
  end

  test "available vendor is inferred, optional failures do not affect availability" do
    [claude, invalid, raising, missing, old] =
      Detector.scan([WithVendor, InvalidVendor, RaisingVendor, Legacy, Old])

    assert claude.available
    assert claude.vendor == "anthropic"

    for cli <- [invalid, raising, missing] do
      assert cli.available
      assert cli.vendor == nil
    end

    assert old.vendor == nil
    refute function_exported?(HelmsmanDaemon.Adapters.Copilot, :vendor, 0)
    refute function_exported?(HelmsmanDaemon.Adapters.Cursor, :vendor, 0)
  end

  test "settings-only changes trigger sync once" do
    start_supervised!({Detector, adapters: [WithVendor], detect_interval_ms: 100_000})
    owner = self()

    connection =
      spawn(fn ->
        receive do
          message -> send(owner, message)
        end
      end)

    Process.register(connection, Connection)
    on_exit(fn -> if Process.alive?(connection), do: Process.exit(connection, :kill) end)
    path = Path.join([System.get_env("HOME"), ".claude", "settings.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"env" => %{"ANTHROPIC_BASE_URL" => "https://api.z.ai"}}))
    Detector.refresh()
    assert_receive {:"$gen_cast", :sync}
    assert [%{vendor: "zai"}] = Detector.inventory()
    Detector.refresh()
    refute_receive {:"$gen_cast", :sync}
  end

  test "old version unavailable and no CLI refuses startup" do
    [old, missing] = Detector.scan([Old, Toggle])
    assert old.version == "1.9.0"
    refute old.available
    assert old.unavailable_reason =~ "too old"
    refute missing.available
    Process.flag(:trap_exit, true)
    assert {:error, :no_cli} = Detector.start_link(adapters: [Old, Toggle])
  end

  test "changed inventory sends one sync" do
    Process.register(self(), :detector_toggle)
    start_supervised!({Detector, adapters: [Toggle], detect_interval_ms: 100_000})
    assert [%{efforts: ["low", "high"]}] = Detector.inventory()
    assert [%{efforts: []}] = Detector.scan([Old])
    owner = self()

    fake_connection =
      spawn(fn ->
        receive do
          message -> send(owner, message)
        end
      end)

    Process.register(fake_connection, HelmsmanDaemon.Connection)
    Process.unregister(:detector_toggle)
    Detector.refresh()
    assert_receive {:"$gen_cast", :sync}
    [cli] = Detector.inventory()
    refute cli.available
    Detector.refresh()
    refute_receive {:"$gen_cast", :sync}
  end

  test "join and sync transmit detected efforts, including legacy defaults" do
    Process.register(self(), :detector_toggle)
    start_execution()

    for {adapter, efforts} <- [{Toggle, ["low", "high"]}, {Legacy, []}] do
      stop_supervised(Detector)
      start_supervised!({Detector, adapters: [adapter], detect_interval_ms: 100_000})

      client =
        start_supervised!(
          {Connection,
           test_mode?: true,
           credentials: credentials(),
           heartbeat_interval_ms: 100_000,
           rotation_interval_ms: 100_000}
        )

      accept_connect(client)
      response = %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}
      assert_join("daemon:1", join, {:ok, response}, 1_000)
      assert {:ok, %Report.Join{clis: [%{efforts: ^efforts}]}} = Messages.decode("join", join)
      assert_push("daemon:1", "claim", %{}, claim, 1_000)
      reply(client, claim, {:ok, %{"runs" => []}})

      GenServer.cast(client, :sync)
      assert_push("daemon:1", "sync", sync, ref, 1_000)
      assert {:ok, %Report.Sync{clis: [%{efforts: ^efforts}]}} = Messages.decode("sync", sync)
      reply(client, ref, {:ok, response})
      stop_supervised(Connection)
    end
  end

  test "version probe timeout kills the entire hanging probe", %{tmp_dir: dir} do
    file = Path.join(dir, "hanging")
    File.write!(file, "#!/bin/sh\nsleep 15\n")
    File.chmod!(file, 0o700)
    start = System.monotonic_time(:millisecond)
    assert {:error, "CLI version command timed out"} = Exec.version(file, timeout: 100)
    assert System.monotonic_time(:millisecond) - start < 1_000
  end
end
