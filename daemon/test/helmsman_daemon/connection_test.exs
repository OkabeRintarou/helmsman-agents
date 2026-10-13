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

  # Slipstream turns `{"status":"ok","response":{}}` into the bare atom `:ok`
  # (add-run-lifecycle reviews/daemon-issue-1.md): an empty reply is a reply,
  # not a transport error to resend.
  test "an empty reply in Slipstream's shape (:ok) is accepted, not resent" do
    client = start_connection(push_timeout_ms: 5_000, report_backoff_ms: [20])
    join_connection(client)
    started = Connection.report(1, %Report.Started{run_id: 1, session_id: nil})

    assert_push("daemon:1", "started", _, ref, 1_000)
    reply(client, ref, :ok)
    assert_receive {:report_result, ^started, {:ok, %Reply.Empty{}}}
    refute_push("daemon:1", "started", _, 100)
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

  test "a normal topic close reconnects and requeues in-flight reports" do
    client = start_connection(reconnect_after_ms: [10])
    join_connection(client)
    report_ref = Connection.report(1, %Report.Events{run_id: 1, events: [event()]})
    assert_push("daemon:1", "events", first_wire, _, 1_000)

    :erlang.trace(client, true, [:receive])
    send(client, Slipstream.Signatures.event(%Slipstream.Events.TopicLeft{topic: "daemon:1"}))
    eventually(fn -> not :sys.get_state(client).assigns.joined? end)
    assert_disconnect()
    assert_receive {:trace, ^client, :receive, :reconnect}, 1_000
    :erlang.trace(client, false, [:receive])
    join_connection(client)

    assert_push("daemon:1", "events", second_wire, ref, 1_000)
    assert second_wire == first_wire
    reply(client, ref, {:ok, %{"acked_seq" => 1}})
    assert_receive {:report_result, ^report_ref, {:ok, %Reply.Events{acked_seq: 1}}}
  end

  test "a normal topic close while stopping leaves the connection unchanged" do
    client = start_connection()
    join_connection(client)
    socket = :sys.get_state(client) |> Slipstream.Socket.assign(:stopping?, true)

    assert {:ok, ^socket} = Connection.handle_leave("daemon:1", socket)
    refute_receive :reconnect, 30
    refute_disconnect()
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

  test "config_changed sends one sync, detector change sync; steer for no run sends nothing" do
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

  # add-run-steering 2.4 (decision 9).
  test "steer is handed to the run's worker" do
    client = start_connection()
    join_connection(client)
    Registry.register(HelmsmanDaemon.RunRegistry, 7, %{last_seq: 0, pgid: nil})
    push(client, "daemon:1", "steer", %{"run_id" => 7, "feedback_id" => 31, "text" => "hello"})
    assert_receive {:"$gen_cast", {:steer, 31, "hello"}}, 1_000
  end

  test "a steer_ack in flight is sent again after a reconnect" do
    client = start_connection(reconnect_after_ms: [10])
    join_connection(client)
    ack = Connection.report(1, %Report.SteerAck{run_id: 1, feedback_id: 31})
    assert_push("daemon:1", "steer_ack", first_wire, _, 1_000)
    assert first_wire == %{"run_id" => 1, "feedback_id" => 31}
    send(client, Slipstream.Signatures.event(%Slipstream.Events.ChannelClosed{reason: :closed}))
    eventually(fn -> not :sys.get_state(client).assigns.joined? end)
    Process.sleep(20)
    join_connection(client)
    assert_push("daemon:1", "steer_ack", ^first_wire, ref, 1_000)
    reply(client, ref, :ok)
    assert_receive {:report_result, ^ack, {:ok, %Reply.Empty{}}}
  end

  test "a steer_ack answered wrong_state is reported to the worker" do
    client = start_connection()
    join_connection(client)
    ack = Connection.report(1, %Report.SteerAck{run_id: 1, feedback_id: 31})
    assert_push("daemon:1", "steer_ack", _, ref, 1_000)
    reply(client, ref, {:error, %{"reason" => "wrong_state", "message" => "ended"}})
    assert_receive {:report_result, ^ack, {:error, %{reason: :wrong_state}}}
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

  test "claim passes explicit worker options and the authenticated server URL", %{tmp_dir: dir} do
    fixture = HelmsmanDaemon.GitHelpers.fixture(dir)
    run = HelmsmanDaemon.GitHelpers.repo_spec(fixture, 803)

    scenario =
      scenario!(
        Path.join(dir, "claimed-cli"),
        "dump_server_url\njson {\"type\":\"result\",\"data\":{\"text\":\"done\",\"success\":true}}\n"
      )

    run = %{run | agent: %{run.agent | custom_args: [scenario]}}

    client =
      start_connection(
        run_worker_opts: [
          allow_file_urls: true,
          reporter: TestReporter,
          server_url: "https://invalid.example"
        ]
      )

    accept_connect(client)

    assert_join(
      "daemon:1",
      _,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    assert_push("daemon:1", "claim", %{}, ref, 1_000)
    reply(client, ref, {:ok, %{"runs" => [HelmsmanProtocol.RunSpec.to_wire(run)]}})
    assert_push("daemon:1", "claim", %{}, next, 1_000)
    reply(client, next, {:ok, %{"runs" => []}})
    assert_receive {:report, 803, %Report.Started{}, _, _, _}, 10_000
    assert_receive {:report, 803, %Report.Finished{status: :succeeded}, _, _, _}, 10_000

    assert File.read!(Path.join(Paths.run(803), "raw.log")) =~ "http://localhost:49999"
    refute File.read!(Path.join(Paths.run(803), "raw.log")) =~ "invalid.example"
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

  test "git_token and pushed business errors keep worker and queued reports alive" do
    {:ok, worker} =
      Runs.start_run(spec(70, "stalled"), reporter: TestReporter, kill_timeout_ms: 50)

    assert_receive {:report, 70, %Report.Started{}, _, _, _}, 2_000
    client = start_connection()
    join_connection(client)

    for payload <- [
          %Report.GitToken{run_id: 70},
          %Report.Pushed{
            run_id: 70,
            branch: "hm/1/bos-1",
            base_sha: String.duplicate("a", 40),
            head_sha: String.duplicate("b", 40),
            commits: [],
            rescue_branch: nil
          }
        ],
        reason <- [:not_found, :wrong_state, :invalid_payload] do
      report_ref = Connection.report(70, payload)
      event = if match?(%Report.GitToken{}, payload), do: "git_token", else: "pushed"
      assert_push("daemon:1", ^event, _, ref, 1_000)

      reply(
        client,
        ref,
        {:error, %{"reason" => Atom.to_string(reason), "message" => "unavailable"}}
      )

      assert_receive {:report_result, ^report_ref, {:error, %{reason: ^reason}}}, 1_000
      assert Process.alive?(worker)
    end

    Runs.cancel(70)
    assert_receive {:report, 70, %Report.Finished{status: :cancelled}, _, _, _}, 2_000
  end

  test "heartbeat termination of repo run commits and reports push but no finished", %{
    tmp_dir: dir
  } do
    alias HelmsmanDaemon.GitHelpers
    fixture = GitHelpers.fixture(dir)
    run = GitHelpers.repo_spec(fixture, 71)
    scenario = scenario!(Path.join(dir, "terminate-cli"), "write stopped\nsleep 600\n")
    run = %{run | agent: %{run.agent | custom_args: [scenario]}}

    {:ok, worker} =
      Runs.start_run(run, reporter: TestReporter, allow_file_urls: true, kill_timeout_ms: 50)

    assert_receive {:report, 71, %Report.Started{}, _, _, _}, 10_000

    eventually(fn ->
      File.exists?(Path.join(HelmsmanDaemon.GitWorkspace.worktree_path(run), "hello.txt"))
    end)

    client = start_connection()
    join_connection(client)
    send(client, :periodic)
    assert_push("daemon:1", "heartbeat", _, ref, 1_000)
    assert_push("daemon:1", "claim", _, claim_ref, 1_000)
    reply(client, claim_ref, {:ok, %{"runs" => []}})
    reply(client, ref, {:ok, %{"terminate_run_ids" => [71]}})
    assert_receive {:report, 71, %Report.Pushed{} = report, _, _, _}, 6_000

    assert report.head_sha ==
             GitHelpers.git!(fixture.git, fixture.remote, [
               "rev-parse",
               "refs/heads/" <> run.repo.branch
             ])

    eventually(fn -> not Process.alive?(worker) end)
    refute_receive {:report, 71, %Report.Finished{}, _, _, _}
  end
end
