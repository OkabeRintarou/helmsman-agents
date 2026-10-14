defmodule HelmsmanDaemon.ConnectionRepoRequestsTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  @moduletag :tmp_dir
  require Slipstream.Signatures
  import ExUnit.CaptureLog
  import HelmsmanDaemon.WebRepoHelpers
  import HelmsmanDaemon.LocalRepoHelpers, only: [served: 1]
  alias HelmsmanDaemon.{Connection, LocalMergeCheck, RepoRequests}
  alias HelmsmanProtocol.Messages

  setup do
    home = web_home()
    code = dir!(Path.join(home, "code"))
    allow!(["~/code"])
    served([{7, "acme"}])
    %{code: code}
  end

  defp runtime,
    do: %{
      "workspace_id" => 7,
      "workspace_slug" => "acme",
      "provider" => "claude",
      "runtime_id" => 7
    }

  defp join_reply,
    do: {:ok, %{"daemon_id" => 1, "runtimes" => [runtime()], "terminate_run_ids" => []}}

  defp start(opts \\ [], request_opts \\ []) do
    start_execution()
    start_supervised!({LocalMergeCheck, repo_status_sender: fn _ -> :ok end})
    start_supervised!({Task.Supervisor, name: HelmsmanDaemon.RepoTaskSupervisor})
    start_supervised!({RepoRequests, request_opts})

    client =
      start_supervised!(
        {Connection,
         Keyword.merge(
           [
             test_mode?: true,
             credentials: credentials(),
             stop: fn code -> raise "unexpected daemon exit #{code}" end,
             heartbeat_interval_ms: 100_000,
             rotation_interval_ms: 100_000,
             config_check_interval_ms: 100,
             reconnect_after_ms: [10]
           ],
           opts
         )}
      )

    accept_connect(client)
    assert_join("daemon:1", join, join_reply(), 1_000)
    assert join["repo_registration"] == true
    assert_push("daemon:1", "claim", %{}, ref, 1_000)
    reply(client, ref, {:ok, %{"runs" => []}})
    client
  end

  defp wire(push) do
    {:ok, {event, wire}} = Messages.encode(push, 7)
    {event, wire}
  end

  defp send_push(client, push) do
    {event, wire} = wire(push)
    push(client, "daemon:1", event, wire)
  end

  test "a successful registration sends sync with the new entry, then the result", %{code: code} do
    app = repo!(Path.join(code, "app"))
    client = start()
    push = register_push([])
    send_push(client, push)

    assert_push("daemon:1", first, sync, sync_ref, 5_000)
    assert first == "sync"
    assert [%{"name" => "app", "path" => ^app, "available" => true}] = sync["local_repositories"]
    assert sync["repo_registration"] == true
    reply(client, sync_ref, join_reply())

    assert_push("daemon:1", second, result, ref, 1_000)
    assert second == "repo_change_result"
    reply(client, ref, :ok)

    assert {:ok, %Report.RepoChangeResult{error: nil, action: :register, name: "app"}} =
             Messages.decode("repo_change_result", result)

    assert result["request_id"] == push.request_id
    # The config_stamp is fresh: the periodic check sends no further sync.
    refute_push("daemon:1", "sync", _, 400)
  end

  test "a refused request sends only the result", %{code: code} do
    repo!(Path.join(code, "app"))
    client = start()
    send_push(client, register_push(path: "missing"))
    assert_push("daemon:1", event, result, ref, 5_000)
    assert event == "repo_change_result"
    assert result["error"] == "missing"
    reply(client, ref, {:error, %{"reason" => "invalid_payload", "message" => "x"}})
    refute_push("daemon:1", "sync", _, 300)
  end

  test "a browse result is pushed once and its reply timeout is not retried", %{code: code} do
    repo!(Path.join(code, "app"))
    client = start(push_timeout_ms: 50)
    browse = %HelmsmanProtocol.Push.RepoBrowse{request_id: request_id()}
    send_push(client, browse)
    assert_push("daemon:1", "repo_browse_result", result, _ref, 5_000)
    assert result["roots"] == ["~/code"]
    assert [%{"path" => "app", "name" => "app"}] = result["repositories"]
    refute_push("daemon:1", "repo_browse_result", _, 300)
  end

  test "results are dropped while disconnected and logged", %{code: code} do
    repo!(Path.join(code, "app"))
    client = start(reconnect_after_ms: [60_000])
    send(client, Slipstream.Signatures.event(%Slipstream.Events.ChannelClosed{reason: :closed}))
    eventually(fn -> not :sys.get_state(client).assigns.joined? end)

    report = %Report.RepoChangeResult{
      request_id: request_id(),
      action: :register,
      name: "app",
      error: nil,
      message: nil
    }

    log =
      capture_log([level: :info], fn ->
        Connection.repo_result(report, true)
        :sys.get_state(client)
      end)

    assert log =~ "Dropped the result of web request #{report.request_id}: not connected"
    refute_push("daemon:1", _, _, 100)
  end

  test "heartbeats continue while a browse is running" do
    test = self()

    blocking = fn ->
      if Process.get(:released) != true do
        send(test, {:blocked, self()})
        receive do: (:go -> Process.put(:released, true))
      end
    end

    client = start([heartbeat_interval_ms: 50], browse_on_visit: blocking)
    send_push(client, %HelmsmanProtocol.Push.RepoBrowse{request_id: request_id()})
    assert_receive {:blocked, task}, 5_000

    assert heartbeats(client, 2) == :ok
    send(task, :go)
    assert %{"error" => nil} = await(client, "repo_browse_result")
  end

  # Answers claims and heartbeats until `count` heartbeats arrived.
  defp heartbeats(_client, 0), do: :ok

  defp heartbeats(client, count) do
    assert_push("daemon:1", event, _, ref, 1_000)

    case event do
      "heartbeat" ->
        reply(client, ref, {:ok, %{"terminate_run_ids" => []}})
        heartbeats(client, count - 1)

      "claim" ->
        reply(client, ref, {:ok, %{"runs" => []}})
        heartbeats(client, count)
    end
  end

  test "a result that cannot be encoded is logged and dropped; the connection survives" do
    client = start()

    report = %Report.RepoChangeResult{
      request_id: request_id(),
      action: :register,
      name: "Not Valid",
      error: :invalid_name,
      message: nil
    }

    log =
      capture_log(fn ->
        Connection.repo_result(report, false)
        :sys.get_state(client)
      end)

    assert log =~ "Could not encode the result of web request #{report.request_id}"
    assert Process.alive?(client)
    refute_push("daemon:1", "repo_change_result", _, 100)
  end

  defp await(client, target) do
    assert_push("daemon:1", event, payload, ref, 5_000)

    if event == target do
      payload
    else
      answer(client, event, ref)
      await(client, target)
    end
  end

  defp answer(client, "heartbeat", ref),
    do: reply(client, ref, {:ok, %{"terminate_run_ids" => []}})

  defp answer(client, "claim", ref), do: reply(client, ref, {:ok, %{"runs" => []}})

  test "protocol 6 connections cannot receive these pushes (encoding refuses them)" do
    for push <- [
          register_push([]),
          remove_push("app"),
          %HelmsmanProtocol.Push.RepoBrowse{request_id: request_id()}
        ] do
      assert {:error, {:not_in_version, 6}} = Messages.encode(push, 6)
    end
  end
end
