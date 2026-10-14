defmodule HelmsmanWeb.DaemonSyncBusyTest do
  use ExUnit.Case, async: false

  @moduletag :e2e
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.AgentsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{CommittedData, DaemonE2E, Daemons, Repo}
  alias Helmsman.Daemons.Runtime
  alias HelmsmanWeb.Endpoint

  @port_output_limit 16_000

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {owner, alpha, scope, daemon, token} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "daemon-e2e-#{tag}@test.invalid"})
        alpha = workspace_fixture(owner, %{slug: "busy-alpha-#{tag}", name: "Busy alpha #{tag}"})
        scope = workspace_scope_fixture(owner, alpha)
        {daemon, token} = daemon_fixture(owner, %{workspace_ids: [alpha.id]})
        {owner, alpha, scope, daemon, token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)

    %{owner: owner, alpha: alpha, scope: scope, daemon: daemon, token: token}
  end

  test "a daemon reconnects and rejoins after sync returns wrong_state from a busy lock",
       %{owner: owner, alpha: alpha, scope: scope, daemon: daemon, token: token} do
    run_tag = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-daemon-sync-#{run_tag}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    previous_busy = Application.get_env(:helmsman, :daemon_locked_force_busy)

    on_exit(fn ->
      if is_nil(previous_busy),
        do: Application.delete_env(:helmsman, :daemon_locked_force_busy),
        else: Application.put_env(:helmsman, :daemon_locked_force_busy, previous_busy)
    end)

    restart_endpoint_on_random_port()
    {:ok, {{127, 0, 0, 1}, port}} = Endpoint.server_info(:http)

    write_credentials(home, "http://127.0.0.1:#{port}", daemon.id, token)
    port_ref = DaemonE2E.start_daemon(home)

    wait_until(
      fn ->
        case Repo.get_by(Runtime, daemon_id: daemon.id, workspace_id: alpha.id) do
          %Runtime{status: "online"} -> true
          _ -> false
        end
      end,
      port_ref,
      "initial daemon join"
    )

    channel_pid = wait_for_channel(daemon.id, port_ref)
    channel_ref = Process.monitor(channel_pid)
    :erlang.trace(channel_pid, true, [:send])

    beta =
      CommittedData.unboxed(fn ->
        workspace_fixture(owner, %{slug: "busy-beta-#{run_tag}", name: "Busy beta #{run_tag}"})
      end)

    # set_workspaces queues config_changed as an after-commit callback. The
    # outer transaction arms busy before the callback is broadcast, so it is
    # consumed by sync rather than by set_workspaces.
    assert {:ok, _daemon} =
             CommittedData.unboxed(fn ->
               Helmsman.Tx.run(fn ->
                 result = Daemons.set_workspaces(scope, daemon.id, [alpha.id, beta.id])
                 Application.put_env(:helmsman, :daemon_locked_force_busy, 1)
                 result
               end)
             end)

    wait_until(
      fn -> Application.get_env(:helmsman, :daemon_locked_force_busy, 0) == 0 end,
      port_ref,
      "busy failure consumed by sync"
    )

    receive do
      {:DOWN, ^channel_ref, :process, ^channel_pid, _reason} -> :ok
    after
      5_000 ->
        flunk(
          "daemon topic did not close after busy sync; daemon output:\n#{captured_output(port_ref)}"
        )
    end

    assert_busy_reply_and_topic_close(channel_pid)

    wait_until(
      fn ->
        case Repo.get_by(Runtime, daemon_id: daemon.id, workspace_id: beta.id) do
          %Runtime{status: "online"} -> true
          _ -> false
        end
      end,
      port_ref,
      "reconnected join registers beta"
    )

    assert_port_alive!(port_ref)
    assert Repo.get_by!(Runtime, daemon_id: daemon.id, workspace_id: alpha.id).status == "online"
    assert Repo.get_by!(Runtime, daemon_id: daemon.id, workspace_id: beta.id).status == "online"
  end

  defp write_credentials(home, server_url, daemon_id, token) do
    path = Path.join(home, "credentials")
    File.write!(Path.join(home, "config.toml"), "server_url = \"#{server_url}\"\n")

    data = %{
      server_url: server_url,
      daemon_id: daemon_id,
      token: token,
      issued_at: DateTime.to_iso8601(DateTime.utc_now(:second)),
      workspaces: []
    }

    File.write!(path, Jason.encode!(data))
    File.chmod!(path, 0o600)
  end

  defp restart_endpoint_on_random_port do
    previous = Application.fetch_env!(:helmsman, Endpoint)
    :ok = Supervisor.terminate_child(Helmsman.Supervisor, Endpoint)

    Application.put_env(
      :helmsman,
      Endpoint,
      Keyword.merge(previous, server: true, http: [ip: {127, 0, 0, 1}, port: 0])
    )

    assert {:ok, _pid} = Supervisor.restart_child(Helmsman.Supervisor, Endpoint)

    on_exit(fn ->
      :ok = Supervisor.terminate_child(Helmsman.Supervisor, Endpoint)
      Application.put_env(:helmsman, Endpoint, previous)
      assert {:ok, _pid} = Supervisor.restart_child(Helmsman.Supervisor, Endpoint)
    end)
  end

  defp wait_for_channel(daemon_id, port, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_channel_loop("daemon:#{daemon_id}", port, deadline)
  end

  defp wait_for_channel_loop(topic, port, deadline) do
    drain_port(port)

    case Registry.lookup(Helmsman.PubSub, topic)
         |> Enum.map(&elem(&1, 0))
         |> Enum.reject(&(&1 == self())) do
      [channel_pid | _] ->
        channel_pid

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("daemon channel did not subscribe; daemon output:\n#{captured_output(port)}")
        else
          assert_port_alive!(port)
          Process.sleep(25)
          wait_for_channel_loop(topic, port, deadline)
        end
    end
  end

  defp wait_until(fun, port, label, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until_loop(fun, port, label, deadline)
  end

  defp wait_until_loop(fun, port, label, deadline) do
    drain_port(port)

    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for #{label}; daemon output:\n#{captured_output(port)}")

      true ->
        assert_port_alive!(port)
        Process.sleep(50)
        wait_until_loop(fun, port, label, deadline)
    end
  end

  defp assert_busy_reply_and_topic_close(channel_pid, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    assert_busy_reply_and_topic_close_loop(channel_pid, deadline, false, false, [])
  end

  defp assert_busy_reply_and_topic_close_loop(channel_pid, deadline, wrong_state?, closed?, seen) do
    cond do
      wrong_state? and closed? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "expected outgoing phx_reply response.reason=wrong_state and socket_close " <>
            "from #{inspect(channel_pid)}; traced sends: #{inspect(Enum.reverse(seen))}"
        )

      true ->
        receive do
          {:trace, ^channel_pid, :send, {:socket_push, :text, wire}, _transport} ->
            is_wrong_state_reply = wrong_state_reply?(wire)

            assert_busy_reply_and_topic_close_loop(
              channel_pid,
              deadline,
              wrong_state? or is_wrong_state_reply,
              closed?,
              [trace_summary(wire) | seen]
            )

          {:trace, ^channel_pid, :send, {:socket_close, ^channel_pid, reason}, _transport} ->
            assert_busy_reply_and_topic_close_loop(
              channel_pid,
              deadline,
              wrong_state?,
              true,
              [{:socket_close, reason} | seen]
            )

          {:trace, ^channel_pid, :send, _other, _to} ->
            assert_busy_reply_and_topic_close_loop(
              channel_pid,
              deadline,
              wrong_state?,
              closed?,
              seen
            )
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            flunk(
              "expected outgoing phx_reply response.reason=wrong_state and socket_close " <>
                "from #{inspect(channel_pid)}; traced sends: #{inspect(Enum.reverse(seen))}"
            )
        end
    end
  end

  defp wrong_state_reply?(wire) do
    with {:ok, [_, _, topic, "phx_reply", %{"response" => response, "status" => "error"}]} <-
           Jason.decode(IO.iodata_to_binary(wire)),
         "daemon:" <> _daemon_id <- topic do
      Map.get(response, "reason") == "wrong_state"
    else
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  defp trace_summary(wire) do
    case Jason.decode(IO.iodata_to_binary(wire)) do
      {:ok, [_, _, topic, event, payload]} -> {event, topic, payload}
      _ -> :unparsed_socket_push
    end
  rescue
    ArgumentError -> :unparsed_socket_push
  end

  defp drain_port(port) do
    receive do
      {^port, {:data, output}} ->
        record_port_output(port, output)
        drain_port(port)
    after
      0 -> :ok
    end
  end

  defp assert_port_alive!(port) do
    receive do
      {^port, {:exit_status, status}} ->
        drain_port(port)

        flunk(
          "daemon process exited with status #{status}; daemon output:\n#{captured_output(port)}"
        )
    after
      0 -> :ok
    end
  end

  defp record_port_output(port, output) do
    key = {:daemon_port_output, port}
    previous = Process.get(key, <<>>)
    combined = IO.iodata_to_binary([previous, output])

    clipped =
      if byte_size(combined) > @port_output_limit do
        binary_part(combined, byte_size(combined) - @port_output_limit, @port_output_limit)
      else
        combined
      end

    Process.put(key, clipped)
  end

  defp captured_output(port) do
    drain_port(port)
    Process.get({:daemon_port_output, port}, "<no daemon output captured>")
  end
end
