defmodule HelmsmanDaemon.RepoCacheTest do
  use HelmsmanDaemon.Case, async: false
  alias HelmsmanDaemon.{Connection, Git, Paths, ProcGroup, RepoCache}
  @moduletag :tmp_dir

  test "global locks work on a non-distributed node" do
    assert node() == :nonode@nohost
    assert RepoCache.with_repo_lock(make_ref(), fn -> :held end) == :held
  end

  test "same repository calls serialize, different repositories run in parallel" do
    owner = self()
    key = make_ref()

    holder =
      spawn(fn ->
        RepoCache.with_repo_lock(key, fn ->
          send(owner, :first_entered)

          receive do
            :release -> :ok
          end
        end)

        send(owner, :first_returned)
      end)

    assert_receive :first_entered
    spawn(fn -> RepoCache.with_repo_lock(key, fn -> send(owner, :second_entered) end) end)

    spawn(fn ->
      RepoCache.with_repo_lock(make_ref(), fn -> send(owner, :different_entered) end)
    end)

    assert_receive :different_entered
    refute_receive :second_entered
    send(holder, :release)
    assert_receive :first_returned
    assert_receive :second_entered, 5000
  end

  test "killing holder releases its lock and kills its git process group", %{tmp_dir: root} do
    script = Path.join(root, "git")
    File.write!(script, "#!/bin/sh\nsleep 20 &\nwait\n")
    File.chmod!(script, 0o700)
    owner = self()
    key = make_ref()

    git =
      Git.context(Paths.run(1), "private",
        executable: script,
        on_start: fn group -> send(owner, {:group, group}) end
      )

    holder =
      spawn(fn -> RepoCache.with_repo_lock(key, fn -> Git.run(["fetch"], root, git) end) end)

    assert_receive {:group, group}

    spawn(fn ->
      RepoCache.with_repo_lock(key, fn -> send(owner, {:entered, ProcGroup.snapshot(group)}) end)
    end)

    refute_receive :entered
    Process.exit(holder, :kill)
    assert_receive {:entered, {:ok, []}}, 5000
  end

  test "handoff waits for suspended command collector cleanup, then enters with old group empty",
       %{tmp_dir: root} do
    script = Path.join(root, "barrier-git")
    File.write!(script, "#!/bin/sh\nsleep 20 &\nwait\n")
    File.chmod!(script, 0o700)
    owner = self()
    key = make_ref()
    path = Path.join(Paths.home(), "work/barrier")

    git =
      Git.context(Paths.run(1), "private",
        executable: script,
        on_start: fn group -> send(owner, {:collector, self(), group}) end
      )

    holder =
      spawn(fn ->
        RepoCache.with_worktree_lock(path, fn ->
          RepoCache.with_repo_lock(key, fn -> Git.run(["fetch"], root, git) end)
        end)
      end)

    assert_receive {:collector, collector, group}
    true = :erlang.suspend_process(collector)

    try do
      Process.exit(holder, :kill)

      for lock <- [:repo, :worktree] do
        spawn(fn ->
          fun = fn -> send(owner, {:entered, lock, ProcGroup.snapshot(group)}) end

          if lock == :repo,
            do: RepoCache.with_repo_lock(key, fun),
            else: RepoCache.with_worktree_lock(path, fun)
        end)
      end

      assert {:ok, [_ | _]} = ProcGroup.snapshot(group)
      refute_receive {:entered, _, _}, 200
    after
      if Process.alive?(collector), do: :erlang.resume_process(collector)
    end

    assert_receive {:entered, :repo, {:ok, []}}, 5000
    assert_receive {:entered, :worktree, {:ok, []}}, 5000
  end

  test "failed lock join prevents launch and releases any pins already acquired", %{tmp_dir: root} do
    owner = self()
    key = make_ref()

    holder =
      spawn(fn ->
        RepoCache.with_repo_lock(key, fn ->
          send(owner, :other_held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :other_held
    forged = {{:hm_repo, key}, self()}
    started = fn _ -> send(owner, :started) end
    first = {{:hm_repo, make_ref()}, self()}
    Process.put({RepoCache, :locks}, [first, forged])

    try do
      assert {:error, {:owner_down, _}} =
               HelmsmanDaemon.Exec.command([true_executable()], cd: root, on_start: started)

      refute_receive :started

      spawn(fn ->
        RepoCache.with_repo_lock(elem(elem(first, 0), 1), fn -> send(owner, :pin_released) end)
      end)

      assert_receive :pin_released
    after
      Process.delete({RepoCache, :locks})
      send(holder, :release)
    end
  end

  test "caller death before joining locks never launches git", %{tmp_dir: root} do
    owner = self()
    key = make_ref()

    holder =
      spawn(fn ->
        RepoCache.with_repo_lock(key, fn ->
          HelmsmanDaemon.Exec.command([true_executable()],
            cd: root,
            before_lock: fn ->
              send(owner, {:before_lock, self()})

              receive do
                :continue -> :ok
              end
            end,
            on_start: fn _ -> send(owner, :started) end
          )
        end)
      end)

    assert_receive {:before_lock, collector}
    monitor = Process.monitor(collector)
    caller_monitor = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^holder, :killed}
    send(collector, :continue)
    assert_receive {:DOWN, ^monitor, :process, ^collector, :normal}
    refute_receive :started
    assert RepoCache.with_repo_lock(key, fn -> :acquired end) == :acquired
  end

  test "normal command completion releases cleanup pins before returning", %{tmp_dir: root} do
    key = make_ref()

    assert {:ok, ""} =
             RepoCache.with_repo_lock(key, fn ->
               HelmsmanDaemon.Exec.command([true_executable()], cd: root)
             end)

    owner = self()
    spawn(fn -> RepoCache.with_repo_lock(key, fn -> send(owner, :acquired) end) end)
    assert_receive :acquired
  end

  test "supervised Connection and run registry restarts never drop a caller's worktree lock" do
    start_execution()
    start_supervised!({Connection, credentials: credentials(), heartbeat_interval_ms: 60_000})
    owner = self()
    path = Path.join(Paths.home(), "work/1/BOS-1")

    holder =
      spawn(fn ->
        RepoCache.with_worktree_lock(path, fn ->
          send(owner, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held
    spawn(fn -> RepoCache.with_worktree_lock(path, fn -> send(owner, :entered) end) end)
    refute_receive :entered
    connection = Process.whereis(Connection)
    Process.exit(connection, :kill)

    eventually(fn ->
      pid = Process.whereis(Connection)
      is_pid(pid) and pid != connection
    end)

    refute_receive :entered
    registry = Process.whereis(HelmsmanDaemon.RunRegistry)
    Process.exit(registry, :kill)

    eventually(fn ->
      pid = Process.whereis(HelmsmanDaemon.RunRegistry)
      is_pid(pid) and pid != registry
    end)

    refute_receive :entered
    runs = Process.whereis(Runs)
    Process.exit(runs, :kill)

    eventually(fn ->
      pid = Process.whereis(Runs)
      is_pid(pid) and pid != runs
    end)

    refute_receive :entered
    send(holder, :release)
    assert_receive :entered, 5000
  end

  # `true` lives in /bin on Linux but only in /usr/bin on macOS.
  defp true_executable, do: System.find_executable("true") || flunk("true executable not found")

  test "finalization cache lock obeys its deadline without entering held cache" do
    owner = self()
    key = make_ref()

    holder =
      spawn(fn ->
        RepoCache.with_repo_lock(key, fn ->
          send(owner, :cache_held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :cache_held

    try do
      deadline = System.monotonic_time(:millisecond) + 50

      assert {:error, :timeout} =
               RepoCache.with_repo_lock_until(key, deadline, fn -> flunk("entered held cache") end)

      assert System.monotonic_time(:millisecond) >= deadline
    after
      send(holder, :release)
    end

    assert :entered =
             RepoCache.with_repo_lock_until(
               key,
               System.monotonic_time(:millisecond) + 2_000,
               fn -> :entered end
             )

    assert RepoCache.command_locks() == []
  end
end
