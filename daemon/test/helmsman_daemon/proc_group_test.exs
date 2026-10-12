defmodule HelmsmanDaemon.ProcGroupTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{Exec, ProcGroup}

  test "continuity table compares both PID and start string" do
    for {known, snapshot, expected} <- [
          {[{1, "a"}], [{1, "a"}, {2, "b"}], true},
          {[{1, "a"}], [{2, "b"}], false},
          {[{1, "a"}], [{1, "different"}], false},
          {[], [], false}
        ] do
      assert ProcGroup.continuous?(1, known, snapshot) == expected
    end
  end

  test "snapshot and continuity require a known live identity" do
    {:ok, _, pid} = :exec.run(["/bin/sleep", "600"], [{:group, 0}, :kill_group])
    on_exit(fn -> Exec.signal_group(pid, 9) end)
    {:ok, start} = Exec.proc_start(pid)
    assert {:ok, members} = ProcGroup.snapshot(pid)
    assert {pid, start} in members
    assert ProcGroup.continuous?(pid, [{pid, start}], members)
    refute ProcGroup.continuous?(pid, [{pid, "different"}], members)
    assert {:error, :unrecognized_group} = ProcGroup.recover(pid, [{pid, "different"}])
    assert alive?(pid)
    assert :ok = ProcGroup.recover(pid, members)
    eventually(fn -> not alive?(pid) end)
  end

  test "known member that left group is killed individually without signaling unrelated group" do
    {:ok, _, known} = :exec.run(["/bin/sleep", "600"], [{:group, 0}, :kill_group])
    {:ok, _, other} = :exec.run(["/bin/sleep", "600"], [{:group, 0}, :kill_group])

    on_exit(fn ->
      Exec.signal_group(known, 9)
      Exec.signal_group(other, 9)
    end)

    {:ok, start} = Exec.proc_start(known)
    assert {:ok, %{continuous?: false}} = ProcGroup.step(other, [{known, start}], 9)
    eventually(fn -> not alive?(known) end)
    assert alive?(other)
  end
end
