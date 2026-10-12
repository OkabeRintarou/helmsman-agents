defmodule HelmsmanDaemon.ConnectionTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  @moduletag :tmp_dir
  require Slipstream.Signatures
  alias HelmsmanDaemon.{Connection, Detector}
  alias HelmsmanProtocol.{Event, Messages}
  import ExUnit.CaptureIO

  setup do
    start_execution()
    :ok
  end

  defp start_connection(opts \\ []) do
    start_supervised!(
      {Connection,
       Keyword.merge(
         [
           test_mode?: true,
           credentials: credentials(),
           stop: fn code -> raise "unexpected daemon exit #{code}" end,
           heartbeat_interval_ms: 100_000,
           rotation_interval_ms: 100_000
         ],
         opts
       )}
    )
  end

  defp join_connection(client, active \\ []) do
    accept_connect(client)

    assert_join(
      "daemon:1",
      payload,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => active}},
      1_000
    )

    assert {:ok, %Report.Join{}} = Messages.decode("join", payload)
    assert_push("daemon:1", "claim", %{}, ref, 1_000)
    reply(client, ref, {:ok, %{"runs" => []}})
    payload
  end

  defp event do
    {:ok, event} = Event.new(%{seq: 1, type: :text, data: %{text: "one"}, at: DateTime.utc_now()})
    event
  end

  test "token in header, valid join and no token in URL" do
    client = start_connection()
    socket = :sys.get_state(client)

    assert socket.channel_config.headers == [
             {HelmsmanProtocol.token_header(), credentials().token}
           ]

    refute URI.to_string(socket.channel_config.uri) =~ credentials().token
    assert socket.channel_config.uri.path == "/daemon/socket/websocket"
    payload = join_connection(client)
    assert payload["active_runs"] == []
    assert payload["max_concurrency"] == 4
    assert [%{"provider" => "claude", "available" => true}] = payload["clis"]
  end

  test "events queue before finished and timeout reuses unchanged payload" do
    client = start_connection(push_timeout_ms: 80, report_backoff_ms: [20])
    join_connection(client)
    ref = Connection.report(1, %Report.Events{run_id: 1, events: [event()]})

    finished =
      Connection.report(1, %Report.Finished{
        run_id: 1,
        status: :succeeded,
        failure_reason: nil,
        error: nil,
        session_id: nil,
        summary: nil,
        usage: nil
      })

    assert_push("daemon:1", "events", wire, _first, 1_000)
    refute_push("daemon:1", "finished", _, 50)
    assert_push("daemon:1", "events", retry_wire, retry, 1_000)
    assert retry_wire == wire
    reply(client, retry, {:ok, %{"acked_seq" => 1}})
    assert_receive {:report_result, ^ref, {:ok, %Reply.Events{acked_seq: 1}}}
    assert_push("daemon:1", "finished", _, final_ref, 1_000)
    reply(client, final_ref, {:ok, %{}})
    assert_receive {:report_result, ^finished, {:ok, %Reply.Empty{}}}
  end

  test "disconnect requeues in flight events before later finished" do
    client = start_connection(reconnect_after_ms: [10])
    join_connection(client)
    Connection.report(1, %Report.Events{run_id: 1, events: [event()]})
    assert_push("daemon:1", "events", first_wire, _, 1_000)
    send(client, Slipstream.Signatures.event(%Slipstream.Events.ChannelClosed{reason: :closed}))
    eventually(fn -> not :sys.get_state(client).assigns.joined? end)
    Process.sleep(20)
    join_connection(client)
    assert_push("daemon:1", "events", second_wire, ref, 1_000)
    assert second_wire == first_wire
    reply(client, ref, {:ok, %{"acked_seq" => 1}})
  end

  test "invalid payload and local encoding rejection do not retry" do
    client = start_connection(report_backoff_ms: [10])
    join_connection(client)
    Connection.report(1, %Report.Events{run_id: 1, events: [event()]})
    assert_push("daemon:1", "events", _, ref, 1_000)
    reply(client, ref, {:error, %{"reason" => "invalid_payload", "message" => "bad event"}})
    assert_receive {:report_rejected, :invalid_payload, "bad event"}
    refute_push("daemon:1", "events", _, 100)
    Connection.report(2, %Report.Events{run_id: 2, events: []})
    assert_receive {:report_rejected, :invalid_payload, "local encoding failed"}
    refute_push("daemon:1", "events", _, 100)
  end

  test "config_changed sends one sync, detector change sync and steer sends nothing" do
    client = start_connection()
    join_connection(client)
    push(client, "daemon:1", "config_changed", %{})
    assert_push("daemon:1", "sync", payload, ref, 1_000)
    assert {:ok, %Report.Sync{}} = Messages.decode("sync", payload)
    reply(client, ref, {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}})
    Detector.refresh()
    refute_push("daemon:1", "sync", _, 100)
    push(client, "daemon:1", "steer", %{"run_id" => 1, "feedback_id" => 1, "text" => "hello"})
    refute_push("daemon:1", "steer_ack", _, 100)
  end

  test "claim in flight prevents parallel claiming" do
    client = start_connection()
    accept_connect(client)

    assert_join(
      "daemon:1",
      _,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    assert_push("daemon:1", "claim", %{}, first, 1_000)
    push(client, "daemon:1", "runs_available", %{})
    refute_push("daemon:1", "claim", _, 100)

    reply(
      client,
      first,
      {:ok, %{"runs" => [HelmsmanProtocol.RunSpec.to_wire(spec(1, "stalled"))]}}
    )

    assert_push("daemon:1", "claim", %{}, second, 1_000)
    reply(client, second, {:ok, %{"runs" => []}})
    eventually(fn -> length(Runs.active()) == 1 end)
    Runs.terminate(1)
  end

  test "slots full skips claim and finishing run requests one" do
    File.write!(Path.join(Paths.home(), "config.toml"), "max_concurrency = 2\n")
    # Config reads once at start; use two occupied workers plus a runtime override.
    :sys.replace_state(HelmsmanDaemon.Config, &%{&1 | max_concurrency: 2})
    {:ok, _} = Runs.start_run(spec(1, "stalled"), reporter: TestReporter)
    {:ok, _} = Runs.start_run(spec(2, "stalled"), reporter: TestReporter)
    client = start_connection()
    accept_connect(client)

    assert_join(
      "daemon:1",
      _,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    push(client, "daemon:1", "runs_available", %{})
    refute_push("daemon:1", "claim", _, 100)
    Runs.terminate(1)
    assert_push("daemon:1", "claim", %{}, ref, 2_000)
    reply(client, ref, {:ok, %{"runs" => []}})
    Runs.terminate(2)
  end

  test "rotation checks online expiry only once and persists before reconnect" do
    {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)
    old = %{credentials() | issued_at: DateTime.add(Agent.get(clock, & &1), -29 * 86_400)}
    Credentials.write(old)

    client =
      start_connection(
        credentials: old,
        clock: fn -> Agent.get(clock, & &1) end,
        rotation_interval_ms: 50,
        reconnect_after_ms: [10]
      )

    join_connection(client)
    refute_push("daemon:1", "rotate_token", _, 80)
    Agent.update(clock, &DateTime.add(&1, 2 * 86_400))
    assert_push("daemon:1", "rotate_token", %{}, ref, 1_000)
    Process.sleep(80)
    refute_push("daemon:1", "rotate_token", _, 80)
    reply(client, ref, {:ok, %{"token" => "hmd_rotated"}})
    eventually(fn -> match?({:ok, %{token: "hmd_rotated"}}, Credentials.read()) end)
    send(client, Slipstream.Signatures.event(%Slipstream.Events.ChannelClosed{reason: :closed}))

    eventually(fn ->
      :sys.get_state(client).channel_config.headers == [
        {HelmsmanProtocol.token_header(), "hmd_rotated"}
      ]
    end)

    Agent.stop(clock)
  end

  test "write failure preserves old file, retries saving and reconnects using new token" do
    {:ok, writer} = Agent.start_link(fn -> :fail end)
    old = %{credentials() | issued_at: DateTime.add(DateTime.utc_now(), -31 * 86_400)}
    Credentials.write(old)

    client =
      start_connection(
        credentials: old,
        rotation_interval_ms: 50,
        reconnect_after_ms: [10],
        credentials_writer: fn credentials ->
          if Agent.get(writer, & &1) == :fail,
            do: {:error, :injected},
            else: Credentials.write(credentials)
        end
      )

    join_connection(client)
    assert_push("daemon:1", "rotate_token", %{}, ref, 1_000)
    reply(client, ref, {:ok, %{"token" => "hmd_rotated"}})
    eventually(fn -> :sys.get_state(client).assigns.dirty_credentials? end)
    assert {:ok, ^old} = Credentials.read()
    send(client, Slipstream.Signatures.event(%Slipstream.Events.ChannelClosed{reason: :closed}))

    eventually(fn ->
      :sys.get_state(client).channel_config.headers == [
        {HelmsmanProtocol.token_header(), "hmd_rotated"}
      ]
    end)

    Agent.update(writer, fn _ -> :ok end)
    join_connection(client)
    eventually(fn -> match?({:ok, %{token: "hmd_rotated"}}, Credentials.read()) end)
    refute_push("daemon:1", "rotate_token", _, 100)
    Agent.stop(writer)
  end

  test "offline expiry is checked after join" do
    {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)
    old = %{credentials() | issued_at: Agent.get(clock, & &1)}

    client =
      start_connection(
        credentials: old,
        clock: fn -> Agent.get(clock, & &1) end,
        rotation_interval_ms: 30
      )

    Agent.update(clock, &DateTime.add(&1, 31 * 86_400))
    refute_push("daemon:1", "rotate_token", _, 100)
    join_connection(client)
    assert_push("daemon:1", "rotate_token", %{}, ref, 1_000)
    reply(client, ref, {:ok, %{"token" => "hmd_new"}})
    Agent.stop(clock)
  end

  test "unsupported protocol terminates connection with exit code 4" do
    owner = self()
    client = start_connection(stop: &send(owner, {:stop, &1}))

    output =
      capture_io(fn ->
        Process.group_leader(client, Process.group_leader())
        accept_connect(client)

        assert_join(
          "daemon:1",
          _,
          {:error,
           %{
             "reason" => "unsupported_protocol",
             "message" => "upgrade",
             "server_version" => 2,
             "min_version" => 2,
             "upgrade_url" => "https://example.test/upgrade"
           }},
          1_000
        )

        assert_receive {:stop, 4}, 1_000
      end)

    assert output =~ "server 2"
    assert output =~ "minimum 2"
    assert output =~ "https://example.test/upgrade"
    refute Process.whereis(Connection)
  end

  test "real HTTP 401 authentication rejection stops with code 3" do
    owner = self()
    client = start_connection(stop: &send(owner, {:stop, &1}))

    capture_io(fn ->
      send(
        client,
        Slipstream.Signatures.event(%Slipstream.Events.ChannelConnectFailed{
          reason: {:upgrade_failure, %{status_code: 401, resp_headers: [], reason: :unauthorized}}
        })
      )

      assert_receive {:stop, 3}, 1_000
    end)

    refute Process.alive?(client)
  end

  test "revocation terminates runs, removes credentials and exits" do
    Credentials.write(credentials())
    owner = self()
    client = start_connection(stop: &send(owner, {:stop, &1}))
    join_connection(client)
    {:ok, worker} = Runs.start_run(spec(1, "stalled"), reporter: TestReporter)
    assert_receive {:report, 1, %Report.Started{}, _, _, _}, 1_000

    capture_io(fn ->
      push(client, "daemon:1", "revoked", %{"reason" => "revoked"})
      assert_receive {:stop, 3}, 2_000
    end)

    refute Process.alive?(worker)
    refute File.exists?(Paths.credentials())
  end

  test "reconnect join reconciles active workers and heartbeat terminates requested run" do
    {:ok, first} = Runs.start_run(spec(7, "stalled"), reporter: TestReporter)
    {:ok, second} = Runs.start_run(spec(8, "stalled"), reporter: TestReporter)
    assert_receive {:report, 7, %Report.Started{}, _, _, _}, 1_000
    assert_receive {:report, 8, %Report.Started{}, _, _, _}, 1_000
    client = start_connection()
    payload = join_connection(client, [8])
    assert payload["active_runs"] |> Enum.map(& &1["run_id"]) |> Enum.sort() == [7, 8]
    eventually(fn -> not Process.alive?(second) end)
    assert Process.alive?(first)
    refute_receive {:report, 8, %Report.Finished{}, _, _, _}
    assert_push("daemon:1", "claim", %{}, claim_ref, 1_000)
    reply(client, claim_ref, {:ok, %{"runs" => []}})
    send(client, :periodic)
    assert_push("daemon:1", "heartbeat", heartbeat, ref, 1_000)
    assert Enum.map(heartbeat["runs"], & &1["run_id"]) == [7]
    assert_push("daemon:1", "claim", %{}, periodic_claim, 1_000)
    reply(client, periodic_claim, {:ok, %{"runs" => []}})
    reply(client, ref, {:ok, %{"terminate_run_ids" => [7]}})
    eventually(fn -> not Process.alive?(first) end)
    refute_receive {:report, 7, %Report.Finished{}, _, _, _}
  end

  test "real HTTP 403 stops runs without reconnecting" do
    Credentials.write(credentials())
    owner = self()
    client = start_connection(stop: &send(owner, {:stop, &1}), reconnect_after_ms: [10])
    join_connection(client)

    {:ok, worker} =
      Runs.start_run(spec(19, "stalled"), reporter: TestReporter, kill_timeout_ms: 100)

    assert_receive {:report, 19, %Report.Started{}, _, _, _}, 1_000

    capture_io(fn ->
      send(
        client,
        Slipstream.Signatures.event(%Slipstream.Events.ChannelConnectFailed{
          reason: {:upgrade_failure, %{status_code: 403, resp_headers: [], reason: :forbidden}}
        })
      )

      assert_receive {:stop, 3}, 2_000
    end)

    refute Process.alive?(worker)
    refute Process.alive?(client)
    Process.sleep(50)
    refute Process.whereis(Connection)
  end
end
