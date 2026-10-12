defmodule HelmsmanDaemon.DetectorTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{Detector, Exec}

  defmodule Old do
    def provider, do: :codex
    def detect, do: {:ok, %{version: "1.9.0", models: []}}
    def min_version, do: Version.parse!("2.0.0")
  end

  defmodule Toggle do
    def provider, do: :claude

    def detect do
      if Process.whereis(:detector_toggle),
        do: {:ok, %{version: "2.0.0", models: ["test"]}},
        else: {:error, "missing"}
    end

    def min_version, do: Version.parse!("2.0.0")
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

  test "version probe timeout kills the entire hanging probe", %{tmp_dir: dir} do
    file = Path.join(dir, "hanging")
    File.write!(file, "#!/bin/sh\nsleep 15\n")
    File.chmod!(file, 0o700)
    start = System.monotonic_time(:millisecond)
    assert {:error, "CLI version command timed out"} = Exec.version(file, timeout: 100)
    assert System.monotonic_time(:millisecond) - start < 1_000
  end
end
