defmodule Helmsman.Daemons.ConcurrencyTest do
  # Every participant uses its own committed database connection so the
  # assertions exercise real PostgreSQL row and advisory lock waits.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures
  import Ecto.Query

  alias Helmsman.{CommittedData, Daemons, Members, Repo, Tx}
  alias Helmsman.Daemons.{Daemon, DaemonWorkspace, Runtime}
  alias Helmsman.Daemons.Workers.MarkOffline
  alias HelmsmanProtocol.{CLI, Machine, Report}

  setup do
    tag = System.unique_integer([:positive])

    {owner, daemon_user, alpha, beta, owner_scope, daemon_scope, membership, daemon, token} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@daemon-concurrency.test"})
        daemon_user = user_fixture(%{email: "daemon-#{tag}@daemon-concurrency.test"})
        alpha = workspace_fixture(owner)
        beta = workspace_fixture(owner)
        membership = member_fixture(alpha, daemon_user, :member)
        member_fixture(beta, daemon_user, :member)
        owner_scope = workspace_scope_fixture(owner, alpha)
        daemon_scope = workspace_scope_fixture(daemon_user, alpha)
        {daemon, token} = daemon_fixture(daemon_user, %{workspace_ids: [alpha.id]})
        runtime_fixture(alpha, daemon, %{provider: "claude", status: "online"})

        {owner, daemon_user, alpha, beta, owner_scope, daemon_scope, membership, daemon, token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id, daemon_user.id]) end)

    %{
      alpha: alpha,
      beta: beta,
      daemon: daemon,
      daemon_scope: daemon_scope,
      epoch: daemon.auth_epoch,
      membership: membership,
      owner_scope: owner_scope,
      token: token
    }
  end

  test "register waits for member demotion, then omits the workspace and leaves its runtime offline",
       %{alpha: alpha, daemon: daemon, epoch: epoch, membership: membership, owner_scope: scope} do
    parent = self()

    demotion =
      start(parent, fn ->
        Tx.run(fn ->
          result = Members.change_role(scope, membership.id, :viewer)
          send(parent, {:demotion_held, self(), result})

          receive do
            :commit -> result
          after
            10_000 -> Repo.rollback(:test_barrier_timeout)
          end
        end)
      end)

    assert_receive {:backend, demotion_pid, _backend}, 5_000
    assert demotion_pid == demotion.pid
    assert_receive {:demotion_held, ^demotion_pid, {:ok, _}}, 5_000

    registering = start(parent, fn -> Daemons.register(daemon.id, epoch, report()) end)
    register_backend = backend(registering)
    CommittedData.await_lock_wait(register_backend)

    send(demotion.pid, :commit)
    assert {:ok, _} = Task.await(demotion, 10_000)
    assert {:ok, []} = Task.await(registering, 10_000)

    assert CommittedData.unboxed(fn ->
             Repo.get_by!(Runtime, daemon_id: daemon.id, workspace_id: alpha.id).status
           end) == "offline"

    refute online_runtime?(daemon.id, alpha.id)
  end

  test "register waits for member removal and cannot restore the removed workspace",
       %{alpha: alpha, daemon: daemon, epoch: epoch, membership: membership, owner_scope: scope} do
    parent = self()

    removal =
      start(parent, fn ->
        Tx.run(fn ->
          result = Members.remove(scope, membership.id)
          send(parent, {:removal_held, self(), result})

          receive do
            :commit -> result
          after
            10_000 -> Repo.rollback(:test_barrier_timeout)
          end
        end)
      end)

    assert_receive {:backend, removal_pid, _backend}, 5_000
    assert removal_pid == removal.pid
    assert_receive {:removal_held, ^removal_pid, {:ok, _}}, 5_000

    registering = start(parent, fn -> Daemons.register(daemon.id, epoch, report()) end)
    CommittedData.await_lock_wait(backend(registering))

    send(removal.pid, :commit)
    assert {:ok, _} = Task.await(removal, 10_000)
    assert {:ok, []} = Task.await(registering, 10_000)
    refute online_runtime?(daemon.id, alpha.id)

    refute CommittedData.unboxed(fn ->
             Repo.exists?(
               from dw in DaemonWorkspace,
                 where: dw.daemon_id == ^daemon.id and dw.workspace_id == ^alpha.id
             )
           end)
  end

  test "register retries when set_workspaces adds a workspace before register commits",
       %{beta: beta, daemon: daemon, daemon_scope: scope, epoch: epoch} do
    parent = self()

    setter =
      start(
        parent,
        fn -> Daemons.set_workspaces(scope, daemon.id, [scope.workspace.id, beta.id]) end,
        :daemon_locked
      )

    held(setter)

    registering = start(parent, fn -> Daemons.register(daemon.id, epoch, report()) end)
    CommittedData.await_lock_wait(backend(registering))

    send(setter.pid, :continue)
    assert {:ok, _} = Task.await(setter, 10_000)
    assert {:ok, runtimes} = Task.await(registering, 10_000)
    assert Enum.any?(runtimes, &(&1.workspace_id == beta.id))

    assert CommittedData.unboxed(fn ->
             Repo.exists?(
               from dw in DaemonWorkspace,
                 where: dw.daemon_id == ^daemon.id and dw.workspace_id == ^beta.id
             )
           end)
  end

  test "register commits before a waiting set_workspaces adds the workspace",
       %{beta: beta, daemon: daemon, daemon_scope: scope, epoch: epoch} do
    parent = self()

    registering =
      start(parent, fn -> Daemons.register(daemon.id, epoch, report()) end, :daemon_locked)

    held(registering)

    setter =
      start(parent, fn ->
        Daemons.set_workspaces(scope, daemon.id, [scope.workspace.id, beta.id])
      end)

    CommittedData.await_lock_wait(backend(setter))

    send(registering.pid, :continue)
    assert {:ok, runtimes} = Task.await(registering, 10_000)
    refute Enum.any?(runtimes, &(&1.workspace_id == beta.id))
    assert {:ok, _} = Task.await(setter, 10_000)

    assert CommittedData.unboxed(fn ->
             Repo.exists?(
               from dw in DaemonWorkspace,
                 where: dw.daemon_id == ^daemon.id and dw.workspace_id == ^beta.id
             )
           end)
  end

  test "MarkOffline rechecks after its candidate read when heartbeat refreshes last_seen_at", %{
    alpha: alpha,
    daemon: daemon,
    epoch: epoch
  } do
    clock = DateTime.utc_now(:second)

    CommittedData.unboxed(fn ->
      Repo.update_all(from(d in Daemon, where: d.id == ^daemon.id),
        set: [last_seen_at: DateTime.add(clock, -121), updated_at: clock]
      )
    end)

    parent = self()
    worker = start(parent, fn -> MarkOffline.perform(%{}) end, :daemon_offline_candidates)
    held(worker)

    assert {:ok, :ok} = CommittedData.unboxed(fn -> Daemons.heartbeat(daemon.id, epoch) end)
    send(worker.pid, :continue)
    assert :ok = Task.await(worker, 10_000)

    assert CommittedData.unboxed(fn ->
             Repo.get_by!(Runtime, daemon_id: daemon.id, workspace_id: alpha.id).status
           end) ==
             "online"

    assert DateTime.compare(
             CommittedData.unboxed(fn -> Repo.get!(Daemon, daemon.id).last_seen_at end),
             clock
           ) in [:eq, :gt]
  end

  test "revoke waits for an accepted sync and leaves its runtime offline", %{
    alpha: alpha,
    daemon: daemon,
    daemon_scope: scope,
    epoch: epoch,
    token: token
  } do
    parent = self()

    registering =
      start(parent, fn ->
        Tx.run(fn ->
          result = Daemons.register(daemon.id, epoch, report())
          send(parent, {:sync_accepted, self(), result})

          receive do
            :commit -> result
          after
            10_000 -> Repo.rollback(:test_barrier_timeout)
          end
        end)
      end)

    assert_receive {:backend, registering_pid, _backend}, 5_000
    assert registering_pid == registering.pid
    assert_receive {:sync_accepted, ^registering_pid, {:ok, [_runtime]}}, 5_000

    revoking = start(parent, fn -> Daemons.revoke(scope, daemon.id) end)
    CommittedData.await_lock_wait(backend(revoking))

    send(registering.pid, :commit)
    assert {:ok, [_]} = Task.await(registering, 10_000)
    assert {:ok, %{revoked_at: revoked_at}} = Task.await(revoking, 10_000)
    assert not is_nil(revoked_at)

    refute online_runtime?(daemon.id, alpha.id)
    assert {:error, :unauthorized} = CommittedData.unboxed(fn -> Daemons.authenticate(token) end)
  end

  test "revoke and token rotation race leaves no usable token", %{
    daemon: daemon,
    daemon_scope: scope,
    epoch: epoch,
    token: token
  } do
    parent = self()

    racers = [
      start_at_barrier(parent, fn -> Daemons.revoke(scope, daemon.id) end),
      start_at_barrier(parent, fn -> Daemons.rotate_token(daemon.id, epoch) end)
    ]

    for _ <- racers, do: assert_receive({:ready, _pid, _backend}, 5_000)
    Enum.each(racers, &send(&1.pid, :go))

    [revoke_result, rotation_result] = Task.await_many(racers, 15_000)
    assert {:ok, %{revoked_at: revoked_at}} = revoke_result
    assert not is_nil(revoked_at)

    rotated_token =
      case rotation_result do
        {:ok, rotated} -> rotated
        {:error, :revoked} -> nil
        unexpected -> flunk("unexpected rotation result: #{inspect(unexpected)}")
      end

    assert {:error, :unauthorized} = CommittedData.unboxed(fn -> Daemons.authenticate(token) end)

    if rotated_token do
      assert {:error, :unauthorized} =
               CommittedData.unboxed(fn -> Daemons.authenticate(rotated_token) end)
    end

    refute online_runtime?(daemon.id, scope.workspace.id)
  end

  defp start(parent, fun, hold_at \\ nil) do
    task =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Process.put(:helmsman_test_hook, &hold_at(&1, hold_at, parent))
          send(parent, {:backend, self(), CommittedData.backend_pid()})
          fun.()
        end)
      end)

    stop_on_exit(task)
  end

  defp start_at_barrier(parent, fun) do
    task =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          send(parent, {:ready, self(), CommittedData.backend_pid()})

          receive do
            :go -> fun.()
          after
            10_000 -> {:error, :test_barrier_timeout}
          end
        end)
      end)

    stop_on_exit(task)
  end

  defp stop_on_exit(task) do
    on_exit(fn ->
      if Process.alive?(task.pid) do
        monitor = Process.monitor(task.pid)
        Process.exit(task.pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
        after
          5_000 -> raise "concurrency test task did not stop before data cleanup"
        end
      end
    end)

    task
  end

  defp hold_at(point, point, parent) when not is_nil(point) do
    send(parent, {:held, self()})

    receive do
      :continue -> :ok
    after
      10_000 -> Repo.rollback(:test_hook_timeout)
    end
  end

  defp hold_at(_point, _hold_at, _parent), do: :ok

  defp backend(%Task{pid: pid}) do
    assert_receive {:backend, ^pid, backend}, 5_000
    backend
  end

  defp held(%Task{pid: pid}) do
    assert_receive {:backend, ^pid, _backend}, 5_000
    assert_receive {:held, ^pid}, 5_000
  end

  defp online_runtime?(daemon_id, workspace_id) do
    CommittedData.unboxed(fn ->
      Repo.exists?(
        from r in Runtime,
          where:
            r.daemon_id == ^daemon_id and r.workspace_id == ^workspace_id and
              r.status == "online"
      )
    end)
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
end
