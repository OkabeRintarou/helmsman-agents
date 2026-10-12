defmodule HelmsmanDaemon.CliGuardianTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{Exec, RepoCache}

  defp options do
    [:stdin, {:stdout, self()}, {:stderr, self()}, {:group, 0}, :kill_group, :monitor]
  end

  test "failed lock pin never launches CLI", %{tmp_dir: dir} do
    owner = self()
    key = make_ref()

    holder =
      spawn(fn ->
        RepoCache.with_repo_lock(key, fn ->
          send(owner, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held
    marker = Path.join(dir, "started")
    Process.put({RepoCache, :locks}, [{{:hm_repo, key}, self()}])

    try do
      assert {:error, {:owner_down, _}} =
               Exec.start_cli([System.find_executable("touch"), marker], options())

      refute File.exists?(marker)
    after
      Process.delete({RepoCache, :locks})
      send(holder, :release)
    end
  end

  test "caller death before pin prevents CLI launch", %{tmp_dir: dir} do
    owner = self()
    marker = Path.join(dir, "started")

    caller =
      spawn(fn ->
        RepoCache.with_worktree_lock(Path.join(dir, "worktree"), fn ->
          Exec.start_cli([System.find_executable("touch"), marker], options(),
            before_cli_lock: fn ->
              send(owner, {:before_pin, self()})

              receive do
                :continue -> :ok
              end
            end
          )
        end)
      end)

    assert_receive {:before_pin, guardian}
    monitor = Process.monitor(guardian)
    caller_monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    send(guardian, :continue)
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}
    refute File.exists?(marker)
  end

  test "stdout stderr exit status are direct and normal release drops lock immediately", %{
    tmp_dir: dir
  } do
    lock = RepoCache.acquire_worktree(Path.join(dir, "worktree"))

    assert {:ok, exec_pid, group, guardian} =
             Exec.start_cli(
               [System.find_executable("sh"), "-c", "printf output; printf error >&2; exit 7"],
               options()
             )

    assert_receive {:stdout, ^group, "output"}
    assert_receive {:stderr, ^group, "error"}
    assert_receive {:DOWN, _, :process, ^exec_pid, {:exit_status, status}}
    assert {:status, 7} == :exec.status(status)
    assert :ok = Exec.release_cli(guardian)
    RepoCache.release(lock)
    owner = self()

    spawn(fn ->
      RepoCache.with_worktree_lock(Path.join(dir, "worktree"), fn -> send(owner, :entered) end)
    end)

    assert_receive :entered
  end

  test "leader exit captures later TERM ignoring child before caller dies", %{tmp_dir: dir} do
    owner = self()
    gate = Path.join(dir, "release")
    child_file = Path.join(dir, "child")
    script = Path.join(dir, "cli")

    File.write!(
      script,
      "#!/bin/sh\nwhile [ ! -f '#{gate}' ]; do sleep 0.01; done\nsh -c 'trap \"\" TERM; echo $$ > \"$1\"; exec sleep 30' child '#{child_file}' &\nwhile [ ! -s '#{child_file}' ]; do sleep 0.01; done\nexit 0\n"
    )

    File.chmod!(script, 0o700)
    key = Path.join(dir, "worktree")

    caller =
      spawn(fn ->
        RepoCache.with_worktree_lock(key, fn ->
          {:ok, exec_pid, group, guardian} = Exec.start_cli([script], options())
          send(owner, {:started, group, guardian})

          receive do
            {:DOWN, _, :process, ^exec_pid, _} -> send(owner, :leader_down)
          end

          receive do
            :end -> :ok
          end
        end)
      end)

    assert_receive {:started, group, guardian}, 3_000

    try do
      File.write!(gate, "go")
      assert_receive :leader_down, 3_000
      monitor = Process.monitor(guardian)
      Process.exit(caller, :kill)

      spawn(fn ->
        RepoCache.with_worktree_lock(key, fn ->
          send(owner, {:entered, HelmsmanDaemon.ProcGroup.live_snapshot(group)})
        end)
      end)

      assert_receive {:entered, {:ok, []}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 5_000
    after
      Exec.signal_group(group, 9)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
    end
  end
end
