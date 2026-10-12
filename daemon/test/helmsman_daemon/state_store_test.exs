defmodule HelmsmanDaemon.StateStoreTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{Exec, StateStore}

  test "recovery kills matching process group and removes private files", %{tmp_dir: dir} do
    child_file = Path.join(dir, "child")

    {:ok, _, pid} =
      :exec.run(
        ["/bin/sh", "-c", "sleep 600 & echo $! > \"$CHILD_FILE\"; sleep 600"],
        [{:group, 0}, :kill_group, {:env, [{"CHILD_FILE", child_file}]}]
      )

    on_exit(fn -> Exec.signal_group(pid, 9) end)
    eventually(fn -> File.exists?(child_file) end)
    child = File.read!(child_file) |> String.trim() |> String.to_integer()
    {:ok, start} = Exec.proc_start(pid)
    Paths.private_dir!(Path.join(Paths.run(1), "tmp"))
    File.write!(Path.join(Paths.run(1), "raw.log"), "log")
    :ok = StateStore.write(1, %{os_pid: pid, pgid: pid, proc_start: start})
    assert :ok = StateStore.recover()
    eventually(fn -> not alive?(pid) and not alive?(child) end)
    refute File.exists?(Paths.record(1))
    assert File.ls!(Paths.run(1)) == ["raw.log"]
  end

  test "mismatched start identity never signals process" do
    {:ok, _, pid} = :exec.run(["/bin/sleep", "600"], [{:group, 0}, :kill_group])
    on_exit(fn -> Exec.signal_group(pid, 9) end)
    :ok = StateStore.write(2, %{os_pid: pid, pgid: pid, proc_start: "different identity"})
    StateStore.recover()
    assert alive?(pid)
    assert File.exists?(Paths.record(2))
  end

  test "recovery cleans known member after original group leader has exited", %{tmp_dir: dir} do
    child_file = Path.join(dir, "orphan-child")

    {:ok, _, leader} =
      :exec.run(
        [
          "/bin/sh",
          "-c",
          "sh -c 'trap \"\" TERM; echo $$ > \"$CHILD_FILE\"; exec sleep 600' & wait"
        ],
        [{:group, 0}, :kill_group, {:env, [{"CHILD_FILE", child_file}]}]
      )

    on_exit(fn -> Exec.signal_group(leader, 9) end)
    eventually(fn -> File.exists?(child_file) end)
    child = File.read!(child_file) |> String.trim() |> String.to_integer()
    {:ok, start} = Exec.proc_start(leader)
    {:ok, members} = HelmsmanDaemon.ProcGroup.snapshot(leader)
    assert Enum.any?(members, fn {pid, _} -> pid == child end)

    StateStore.write(3, %{
      os_pid: leader,
      pgid: leader,
      proc_start: start,
      members: HelmsmanDaemon.ProcGroup.to_wire(members)
    })

    Exec.signal_group(leader, 15)
    eventually(fn -> not alive?(leader) end)
    assert alive?(child)
    StateStore.recover()
    eventually(fn -> not alive?(child) end)
    refute File.exists?(Paths.record(3))
  end
end
