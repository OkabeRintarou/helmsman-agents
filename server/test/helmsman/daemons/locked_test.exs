defmodule Helmsman.Daemons.LockedTest do
  # These tests commit fixtures and coordinate independent database connections.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Phoenix.ConnTest, except: [connect: 3]
  import Phoenix.ChannelTest
  import Plug.Conn, only: [put_req_header: 3]
  import Ecto.Query, except: [join: 4]
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{CommittedData, Daemons, Repo}
  alias Helmsman.Daemons.{Daemon, DaemonWorkspace, DeviceCode, Runtime}
  alias Helmsman.Daemons.Workers.MarkOffline
  alias HelmsmanProtocol.{CLI, ErrorReply, Machine, Messages, Report}
  alias HelmsmanProtocol.DeviceAuth.{TokenRequest, TokenResponse}
  alias HelmsmanWeb.{DaemonChannel, DaemonSocket}
  alias Phoenix.Channel.Server

  @endpoint HelmsmanWeb.Endpoint

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = System.unique_integer([:positive])

    {user, workspaces, daemon, runtime, token} =
      CommittedData.unboxed(fn ->
        user = user_fixture(%{email: "daemon-lock-#{tag}@test.invalid"})

        workspaces =
          for suffix <- ~w(a b c d) do
            workspace_fixture(user, %{name: "Lock #{suffix} #{tag}"})
          end

        {daemon, token} = daemon_fixture(user, %{workspace_ids: [hd(workspaces).id]})
        runtime = runtime_fixture(hd(workspaces), daemon)
        {user, workspaces, daemon, runtime, token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([user.id]) end)

    scope = CommittedData.unboxed(fn -> workspace_scope_fixture(user, hd(workspaces)) end)

    %{
      user: user,
      workspaces: workspaces,
      daemon: daemon,
      runtime: runtime,
      token: token,
      scope: scope
    }
  end

  test "revoke retries after another transaction adds a served workspace",
       %{scope: scope, daemon: daemon, runtime: runtime, workspaces: [_a, b | _]} do
    task = pause_at(:daemon_pre_read, fn -> Daemons.revoke(scope, daemon.id) end)
    await_pause(:daemon_pre_read)
    backend = await_target_backend()

    runtime_b = commit_registration(scope, daemon, b)
    blocker = hold_maintenance_lock(b.id)
    continue_pause(task.pid, :daemon_pre_read)
    assert :ok = CommittedData.await_lock_wait(backend, 5_000)
    release_maintenance_lock(blocker)

    assert {:ok, revoked} = Task.await(task, 10_000)
    assert revoked.revoked_at
    assert lock_hook_counts() == %{daemon_pre_read: 2, daemon_locked: 2}

    CommittedData.unboxed(fn ->
      assert Repo.get!(Runtime, runtime.id).status == "offline"
      assert Repo.get!(Runtime, runtime_b.id).status == "offline"
      assert served_workspace_ids(daemon.id) == Enum.sort([scope.workspace.id, b.id])
    end)
  end

  test "set_workspaces retries when the served set grows after its pre-read",
       %{scope: scope, daemon: daemon, workspaces: [_a, b | _]} do
    task =
      pause_at(:daemon_pre_read, fn ->
        Daemons.set_workspaces(scope, daemon.id, [scope.workspace.id])
      end)

    await_pause(:daemon_pre_read)
    backend = await_target_backend()

    runtime_b = commit_registration(scope, daemon, b)
    blocker = hold_maintenance_lock(b.id)
    continue_pause(task.pid, :daemon_pre_read)
    assert :ok = CommittedData.await_lock_wait(backend, 5_000)
    release_maintenance_lock(blocker)

    assert {:ok, _} = Task.await(task, 10_000)
    assert lock_hook_counts() == %{daemon_pre_read: 2, daemon_locked: 2}

    CommittedData.unboxed(fn ->
      assert served_workspace_ids(daemon.id) == [scope.workspace.id]
      assert Repo.get!(Runtime, runtime_b.id).status == "offline"
    end)
  end

  test "exchange_device_code retries against the expanded set before reauthorizing",
       %{scope: scope, daemon: daemon, user: user, workspaces: [_a, b | _]} do
    device_code = insert_approved_code(user, daemon, [scope.workspace.id])
    old_epoch = daemon.auth_epoch

    task = pause_at(:daemon_pre_read, fn -> Daemons.exchange_device_code(device_code) end)
    await_pause(:daemon_pre_read)
    backend = await_target_backend()

    runtime_b = commit_registration(scope, daemon, b)
    blocker = hold_maintenance_lock(b.id)
    continue_pause(task.pid, :daemon_pre_read)
    assert :ok = CommittedData.await_lock_wait(backend, 5_000)
    release_maintenance_lock(blocker)

    assert {:ok, response} = Task.await(task, 10_000)
    assert response.daemon_id == daemon.id
    assert response.token =~ "hmd_"
    assert lock_hook_counts() == %{daemon_pre_read: 2, daemon_locked: 2}

    CommittedData.unboxed(fn ->
      assert Repo.get!(Daemon, daemon.id).auth_epoch == old_epoch + 1
      assert served_workspace_ids(daemon.id) == [scope.workspace.id]
      assert Repo.get!(Runtime, runtime_b.id).status == "offline"
      assert Repo.get!(DeviceCode, code_id(device_code)).status == "used"
    end)
  end

  test "MarkOffline retries and rechecks the daemon after its served set grows",
       %{scope: scope, daemon: daemon, runtime: runtime, workspaces: [_a, b | _]} do
    CommittedData.unboxed(fn ->
      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Daemon, daemon.id),
          last_seen_at: DateTime.add(Daemons.now(), -600)
        )
      )
    end)

    task = pause_at(:daemon_pre_read, fn -> perform_job(MarkOffline, %{}) end)
    await_pause(:daemon_pre_read)
    backend = await_target_backend()

    runtime_b = commit_registration(scope, daemon, b)
    blocker = hold_maintenance_lock(b.id)
    continue_pause(task.pid, :daemon_pre_read)
    assert :ok = CommittedData.await_lock_wait(backend, 5_000)
    release_maintenance_lock(blocker)

    assert :ok = Task.await(task, 10_000)

    assert lock_hook_counts() == %{
             daemon_pre_read: 2,
             daemon_locked: 2,
             daemon_offline_candidates: 1
           }

    CommittedData.unboxed(fn ->
      # The committed registration refreshed last_seen_at after the candidate
      # query; MarkOffline must recheck that state under the expanded lock set.
      assert Repo.get!(Runtime, runtime.id).status == "online"
      assert Repo.get!(Runtime, runtime_b.id).status == "online"
    end)
  end

  test "three consecutive set changes exhaust the retry budget and return busy",
       %{scope: scope, daemon: daemon, workspaces: [a, b, c, d]} do
    parent = self()

    task =
      tracked_task(fn ->
        install_pause_hook(parent, :daemon_pre_read, 3)
        CommittedData.unboxed(fn -> Daemons.revoke(scope, daemon.id) end)
      end)

    for ids <- [[a, b], [a, b, c], [a, b, c, d]] do
      await_pause(:daemon_pre_read)
      commit_service_set(scope, daemon, Enum.map(ids, & &1.id))
      continue_pause(task.pid, :daemon_pre_read)
    end

    assert {:error, :busy} = Task.await(task, 10_000)
    assert lock_hook_counts() == %{daemon_pre_read: 3, daemon_locked: 3}

    CommittedData.unboxed(fn ->
      assert is_nil(Repo.get!(Daemon, daemon.id).revoked_at)
      assert Repo.get!(Daemon, daemon.id).auth_epoch == daemon.auth_epoch

      assert Enum.all?(
               Repo.all(from r in Runtime, where: r.daemon_id == ^daemon.id),
               &(&1.status == "online")
             )
    end)
  end

  test "logout authenticated with the previous device generation cannot revoke a reauthorized daemon",
       %{scope: scope, daemon: daemon, user: user, token: old_token} do
    old_epoch = daemon.auth_epoch
    old_hash = daemon.token_hash
    device_code = insert_approved_code(user, daemon, [scope.workspace.id])

    task = pause_at(:daemon_logout_authenticated, fn -> Daemons.logout(old_token) end)
    await_pause(:daemon_logout_authenticated)

    assert {:ok, %TokenResponse{token: new_token}} =
             CommittedData.unboxed(fn -> Daemons.exchange_device_code(device_code) end)

    new_socket = joined_socket(daemon, new_token)
    Process.unlink(new_socket.channel_pid)
    new_monitor = Process.monitor(new_socket.channel_pid)
    new_topic = socket_topic(new_socket)
    @endpoint.subscribe(new_topic)

    continue_pause(task.pid, :daemon_logout_authenticated)

    assert {:error, :unauthorized} = Task.await(task, 10_000)

    assert lock_hook_counts() == %{
             daemon_logout_authenticated: 1,
             daemon_pre_read: 1,
             daemon_locked: 1
           }

    CommittedData.unboxed(fn ->
      current = Repo.get!(Daemon, daemon.id)
      assert current.auth_epoch == old_epoch + 1
      assert is_nil(current.revoked_at)
      assert current.token_hash == Daemons.hash(new_token)
      assert current.token_hash != old_hash
      assert {:error, :unauthorized} = Daemons.authenticate(old_token)
      assert Repo.get!(Runtime, runtime_id_for(daemon.id, scope.workspace.id)).status == "online"
    end)

    refute_receive %Phoenix.Socket.Broadcast{topic: ^new_topic, event: "disconnect"}, 100
    assert Process.alive?(new_socket.channel_pid)
    Process.demonitor(new_monitor, [:flush])
  end

  test "previous token remains valid for logout during the rotation grace period",
       %{daemon: daemon, token: old_token} do
    assert {:ok, new_token} = Daemons.rotate_token(daemon.id, daemon.auth_epoch)
    assert new_token != old_token
    assert {:ok, authenticated} = Daemons.authenticate(old_token)
    assert authenticated.auth_epoch == daemon.auth_epoch

    assert {:ok, revoked} = Daemons.logout(old_token)
    assert revoked.revoked_at
    assert revoked.auth_epoch == daemon.auth_epoch + 1
    assert Daemons.authenticate(old_token) == {:error, :unauthorized}
    assert Daemons.authenticate(new_token) == {:error, :unauthorized}
  end

  test "device code polling maps busy locking to authorization_pending",
       %{user: user, daemon: daemon, scope: scope} do
    device_code = insert_approved_code(user, daemon, [scope.workspace.id])
    {:ok, request} = TokenRequest.new(%{device_code: device_code})

    response =
      with_forced_busy(3, fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          HelmsmanProtocol.DeviceAuth.token_path(),
          Jason.encode!(TokenRequest.to_wire(request))
        )
      end)

    assert response.status == 400
    assert Jason.decode!(response.resp_body) == %{"error" => "authorization_pending"}
  end

  test "logout maps busy locking to HTTP 503", %{token: token} do
    response =
      with_forced_busy(3, fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header(HelmsmanProtocol.token_header(), token)
        |> post(HelmsmanProtocol.DeviceAuth.logout_path(), "{}")
      end)

    assert response.status == 503
    assert Jason.decode!(response.resp_body) == %{}
  end

  test "busy join replies wrong_state and exits the channel process", %{
    daemon: daemon,
    token: token
  } do
    with_forced_busy(3, fn ->
      {:ok, socket} = connect_daemon(token)
      {result, channel_pid} = join_with_process(socket, daemon)
      monitor = Process.monitor(channel_pid)

      assert {:error, reply} = result
      assert error_reason(reply) == :wrong_state
      assert_receive {:DOWN, ^monitor, :process, ^channel_pid, _reason}, 5_000
    end)
  end

  test "busy sync replies wrong_state and closes the topic process", %{
    daemon: daemon,
    token: token
  } do
    socket = joined_socket(daemon, token)

    with_forced_busy(3, fn ->
      Process.unlink(socket.channel_pid)
      monitor = Process.monitor(socket.channel_pid)

      ref = push(socket, "sync", sync_payload(daemon))
      assert_reply ref, :error, reply
      assert error_reason(reply) == :wrong_state
      assert_receive {:DOWN, ^monitor, :process, pid, _reason}, 5_000
      assert pid == socket.channel_pid
    end)
  end

  defp pause_at(point, fun) do
    parent = self()

    tracked_task(fn ->
      install_pause_hook(parent, point, 1)

      CommittedData.unboxed(fn ->
        send(parent, {:target_backend, CommittedData.backend_pid()})
        fun.()
      end)
    end)
  end

  defp tracked_task(fun) do
    task = Task.async(fun)
    Process.unlink(task.pid)

    on_exit(fn -> terminate_task(task.pid) end)

    task
  end

  defp install_pause_hook(parent, point, pauses) do
    counter = {__MODULE__, :pause_count, make_ref()}
    Process.put(counter, pauses)

    Process.put(:helmsman_test_hook, fn hook ->
      send(parent, {:locked_hook, hook})
      remaining = Process.get(counter, 0)

      if hook == point and remaining > 0 and not Process.get(:locked_test_release_all, false) do
        Process.put(counter, remaining - 1)
        send(parent, {:locked_paused, hook, self()})

        receive do
          {:locked_continue, ^hook} -> :ok
          :locked_release_all -> Process.put(:locked_test_release_all, true)
        after
          8_000 -> send(parent, {:locked_hook_timeout, hook})
        end
      end
    end)
  end

  defp await_pause(point) do
    assert_receive {:locked_hook, ^point}, 5_000
    counts = Process.get(:consumed_lock_hooks, %{})
    Process.put(:consumed_lock_hooks, Map.update(counts, point, 1, &(&1 + 1)))
    assert_receive {:locked_paused, ^point, _pid}, 5_000
  end

  defp continue_pause(pid, point), do: send(pid, {:locked_continue, point})

  defp await_target_backend do
    assert_receive {:target_backend, backend}, 5_000
    backend
  end

  defp connect_daemon(token) do
    connect(DaemonSocket, %{},
      connect_info: %{x_headers: [{HelmsmanProtocol.token_header(), token}]}
    )
  end

  defp joined_socket(daemon, token) do
    {:ok, socket} = connect_daemon(token)

    assert {:ok, _reply, socket} =
             join(socket, DaemonChannel, "daemon:#{daemon.id}", join_payload(daemon))

    socket
  end

  defp join_with_process(socket, daemon) do
    parent = self()
    {Phoenix.ChannelTest, supervisor} = socket.transport

    starter = fn _socket, _from, child_spec ->
      case Supervisor.start_child(supervisor, %{child_spec | id: make_ref()}) do
        {:ok, pid} = started ->
          send(parent, {:channel_started, pid})
          started

        result ->
          result
      end
    end

    message = %Phoenix.Socket.Message{
      event: "phx_join",
      payload: join_payload(daemon),
      topic: "daemon:#{daemon.id}",
      ref: System.unique_integer([:positive])
    }

    result = Server.join(socket, DaemonChannel, message, starter: starter)
    assert_receive {:channel_started, pid}, 5_000
    {result, pid}
  end

  defp join_payload(daemon) do
    {:ok, report} =
      Report.Join.new(%{
        protocol: HelmsmanProtocol.version(),
        machine: machine(daemon),
        clis: [claude()],
        max_concurrency: 4,
        active_runs: []
      })

    encode!(report)
  end

  defp sync_payload(daemon) do
    {:ok, report} =
      Report.Sync.new(%{
        machine: machine(daemon),
        clis: [claude()],
        max_concurrency: 4
      })

    encode!(report)
  end

  defp machine(daemon) do
    %{
      machine_id: daemon.machine_id,
      name: daemon.name,
      os: daemon.os,
      arch: daemon.arch,
      daemon_version: daemon.version
    }
  end

  defp claude do
    %{
      provider: :claude,
      version: "3.2.1",
      models: ["opus-4"],
      efforts: ["high"],
      available: true,
      unavailable_reason: nil
    }
  end

  defp encode!(struct) do
    {:ok, {_name, payload}} = Messages.encode(struct)
    payload
  end

  defp error_reason(payload) do
    assert {:ok, %ErrorReply{} = error} = ErrorReply.from_wire(payload)
    error.reason
  end

  defp socket_topic(socket), do: DaemonSocket.id(socket)

  defp runtime_id_for(daemon_id, workspace_id) do
    Repo.one!(
      from r in Runtime,
        where: r.daemon_id == ^daemon_id and r.workspace_id == ^workspace_id,
        select: r.id
    )
  end

  defp hold_maintenance_lock(workspace_id) do
    parent = self()

    task =
      Task.async(fn ->
        CommittedData.unboxed(fn -> hold_lock_and_wait(parent, workspace_id) end)
      end)

    Process.unlink(task.pid)

    on_exit(fn -> terminate_task(task.pid) end)

    assert_receive {:maintenance_lock_held, pid, _backend}, 5_000
    assert pid == task.pid
    %{task: task, pid: pid}
  end

  defp release_maintenance_lock(%{pid: pid, task: task}) do
    send(pid, :release_maintenance_lock)
    assert {:ok, :ok} = Task.await(task, 5_000)
  end

  defp hold_lock_and_wait(parent, workspace_id) do
    Repo.transact(fn ->
      Helmsman.Locks.maint_exclusive!(workspace_id)
      send(parent, {:maintenance_lock_held, self(), CommittedData.backend_pid()})

      receive do
        :release_maintenance_lock -> {:ok, :ok}
        :locked_release_all -> {:ok, :ok}
      after
        8_000 -> Repo.rollback(:maintenance_lock_test_timeout)
      end
    end)
  end

  defp terminate_task(pid) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        2_000 -> raise "task #{inspect(pid)} did not stop during test cleanup"
      end
    end
  end

  defp with_forced_busy(count, fun) do
    previous = Application.get_env(:helmsman, :daemon_locked_force_busy)
    Application.put_env(:helmsman, :daemon_locked_force_busy, count)

    try do
      fun.()
    after
      case previous do
        nil -> Application.delete_env(:helmsman, :daemon_locked_force_busy)
        value -> Application.put_env(:helmsman, :daemon_locked_force_busy, value)
      end
    end
  end

  defp lock_hook_counts do
    collect_lock_hooks(Process.get(:consumed_lock_hooks, %{}))
  end

  defp collect_lock_hooks(counts) do
    receive do
      {:locked_hook, point} ->
        collect_lock_hooks(Map.update(counts, point, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end

  defp commit_registration(scope, daemon, workspace) do
    commit_service_set(scope, daemon, [scope.workspace.id, workspace.id])

    CommittedData.unboxed(fn ->
      Repo.get_by!(Runtime, daemon_id: daemon.id, workspace_id: workspace.id)
    end)
  end

  defp commit_service_set(scope, daemon, workspace_ids) do
    assert {:ok, _} =
             CommittedData.unboxed(fn ->
               Daemons.set_workspaces(scope, daemon.id, workspace_ids)
             end)

    assert {:ok, registered} =
             CommittedData.unboxed(fn ->
               Daemons.register(daemon.id, daemon.auth_epoch, report())
             end)

    assert Enum.map(registered, & &1.workspace_id) |> Enum.sort() == Enum.sort(workspace_ids)
  end

  defp report do
    %Report.Join{
      protocol: HelmsmanProtocol.version(),
      machine: %Machine{os: "linux", arch: "x86_64", daemon_version: "0.9.0"},
      clis: [
        %CLI{
          provider: :claude,
          version: "3.2.1",
          models: ["opus-4"],
          efforts: ["high"],
          available: true
        }
      ],
      max_concurrency: 4,
      active_runs: []
    }
  end

  defp insert_approved_code(user, daemon, workspace_ids) do
    device_code = "test-device-code-#{System.unique_integer([:positive])}"

    CommittedData.unboxed(fn ->
      Repo.insert!(%DeviceCode{
        device_code_hash: Daemons.hash(device_code),
        user_code: "USED-#{System.unique_integer([:positive])}",
        machine: %{
          "machine_id" => daemon.machine_id,
          "name" => daemon.name,
          "os" => daemon.os,
          "arch" => daemon.arch,
          "daemon_version" => daemon.version
        },
        protocol_version: daemon.protocol_version,
        user_id: user.id,
        workspace_ids: workspace_ids,
        status: "approved",
        expires_at: DateTime.add(Daemons.now(), 600)
      })
    end)

    device_code
  end

  defp served_workspace_ids(daemon_id) do
    Repo.all(
      from w in DaemonWorkspace,
        where: w.daemon_id == ^daemon_id,
        select: w.workspace_id,
        order_by: w.workspace_id
    )
  end

  defp code_id(device_code) do
    Repo.one!(
      from c in DeviceCode, where: c.device_code_hash == ^Daemons.hash(device_code), select: c.id
    )
  end
end
