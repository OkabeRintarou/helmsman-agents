defmodule HelmsmanDaemon.StatusFileTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  require Slipstream.Signatures
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  import HelmsmanDaemon.ServiceCase
  alias HelmsmanDaemon.{CLI, Connection, FakeServiceManager, StatusFile}

  setup do
    start_execution()
    :ok
  end

  defp status do
    case StatusFile.read() do
      {:ok, status} -> status
      _ -> %{}
    end
  end

  defp start_connection do
    start_supervised!(
      {Connection,
       test_mode?: true,
       credentials: credentials(),
       stop: fn code -> raise "unexpected daemon exit #{code}" end,
       heartbeat_interval_ms: 100_000,
       rotation_interval_ms: 100_000,
       reconnect_after_ms: [10],
       run_worker_opts: [reporter: TestReporter]}
    )
  end

  defp join(client) do
    accept_connect(client)

    assert_join(
      "daemon:1",
      _,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    assert_push("daemon:1", "claim", %{}, ref, 1_000)
    ref
  end

  test "connection changes, claims and run ends write status.json" do
    start_supervised!({StatusFile, status_interval_ms: 100_000})
    assert %{"connected" => false, "running_runs" => [], "pid" => pid} = status()
    assert Integer.to_string(pid) == System.pid()

    client = start_connection()
    eventually(fn -> status()["server_url"] == "http://localhost:49999" end)
    assert status()["daemon_id"] == 1

    claim = join(client)
    eventually(fn -> status()["connected"] == true end)
    assert status()["connected_at"]
    assert status()["version"] == HelmsmanDaemon.Release.version()
    assert status()["target"] == "dev"
    assert status()["credentials_store"] == "file"

    reply(
      client,
      claim,
      {:ok, %{"runs" => [HelmsmanProtocol.RunSpec.to_wire(spec(1, "stalled"))]}}
    )

    eventually(fn -> status()["running_runs"] == [1] end)
    assert_push("daemon:1", "claim", %{}, next, 1_000)
    reply(client, next, {:ok, %{"runs" => []}})

    Runs.terminate(1)
    # A free slot makes the daemon claim again.
    assert_push("daemon:1", "claim", %{}, again, 2_000)
    reply(client, again, {:ok, %{"runs" => []}})
    eventually(fn -> status()["running_runs"] == [] end)

    send(client, Slipstream.Signatures.event(%Slipstream.Events.ChannelClosed{reason: :closed}))
    eventually(fn -> status()["connected"] == false end)
  end

  test "the timer rewrites the file; 0600, atomic and without the token" do
    start_supervised!({StatusFile, status_interval_ms: 30})
    StatusFile.identity("https://hm.example.test", 7)
    eventually(fn -> status()["daemon_id"] == 7 end)

    File.rm!(StatusFile.path())
    eventually(fn -> File.exists?(StatusFile.path()) end)

    # Each tick writes the temporary file and renames it within one callback;
    # suspending between callbacks keeps the next tick from racing the checks.
    :ok = :sys.suspend(StatusFile)

    contents =
      try do
        assert Bitwise.band(File.stat!(StatusFile.path()).mode, 0o777) == 0o600
        assert Path.wildcard(StatusFile.path() <> ".*.tmp") == []
        File.read!(StatusFile.path())
      after
        :sys.resume(StatusFile)
      end

    refute contents =~ credentials().token
    refute contents =~ "hmd_"

    for key <- ~w(pid version protocol target server_url daemon_id connected connected_at
                  last_message_at running_runs credentials_store started_at updated_at) do
      assert Map.has_key?(Jason.decode!(contents), key), key
    end
  end

  test "a normal exit deletes the file" do
    start_supervised!({StatusFile, []})
    assert File.exists?(StatusFile.path())
    stop_supervised!(StatusFile)
    refute File.exists?(StatusFile.path())
  end

  test "staleness: old updated_at and no helmsman process" do
    now = DateTime.utc_now()
    old = now |> DateTime.add(-300) |> DateTime.to_iso8601()
    fresh = now |> DateTime.add(-30) |> DateTime.to_iso8601()

    refute StatusFile.live?(%{"updated_at" => old, "pid" => 1}, pid_alive?: fn _ -> false end)
    assert StatusFile.live?(%{"updated_at" => old, "pid" => 1}, pid_alive?: fn _ -> true end)
    assert StatusFile.live?(%{"updated_at" => fresh, "pid" => 1}, pid_alive?: fn _ -> false end)
    refute StatusFile.helmsman_pid?(999_999_999)
  end

  test "process gone: status reports not running with exit 3" do
    {:ok, fake} = FakeServiceManager.start_link(:systemd)
    old = DateTime.utc_now() |> DateTime.add(-300) |> DateTime.to_iso8601()
    write_status(%{"updated_at" => old, "pid" => 999_999_999})
    opts = service_opts(fake, :linux, pid_alive?: &StatusFile.helmsman_pid?/1)

    output = capture_io(fn -> assert CLI.run(["daemon", "status"], opts) == 3 end)
    assert output =~ "Daemon: not running"
    refute output =~ "Connected: yes"
  end
end
