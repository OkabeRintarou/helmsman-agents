defmodule HelmsmanDaemon.FakeCLITest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{Adapters.Fake, Exec}

  @repo_root Path.expand("../../../", __DIR__)

  test "script version and output, JSON, delay, environment, argv and exit", %{tmp_dir: dir} do
    assert {:ok, %{version: "1.0.0"}} = Fake.detect()

    path =
      scenario!(
        Path.join(dir, "scenario"),
        "out hello\njson {\"type\":\"text\",\"data\":{\"text\":\"json\"}}\nsleep 0.05\ndump_env\ndump_argv\nexit 7\n"
      )

    start = System.monotonic_time(:millisecond)

    {out, 7} =
      System.cmd(Fake.executable(), ["--scenario", path, "literal $(false)"],
        cd: dir,
        env: [{"FAKE_CHECK", "value"}]
      )

    assert out =~ "hello\n"
    assert out =~ "{\"type\":\"text\""
    assert out =~ "FAKE_CHECK=value"
    assert out =~ "literal $(false)"
    assert System.monotonic_time(:millisecond) - start >= 50
    error = scenario!(Path.join(dir, "error"), "err stderr message\nexit 3\n")

    assert {"stderr message\n", 3} =
             System.cmd(Fake.executable(), ["--scenario", error],
               cd: dir,
               stderr_to_stdout: true
             )
  end

  test "write instructions stay in the isolated CLI working directory", %{tmp_dir: dir} do
    roots_before = root_entries()
    path = scenario!(Path.join(dir, "write.scenario"), "write agent-change\nexit 0\n")

    # The fake CLI writes relative to its process cwd; keep direct calls isolated.
    assert {"", 0} = System.cmd(Fake.executable(), ["--scenario", path], cd: dir)
    assert File.read!(Path.join(dir, "hello.txt")) == "agent-change\n"
    assert_root_entries_unchanged(roots_before)
  end

  test "echo stdin uses CLI input rather than consuming scenario", %{tmp_dir: dir} do
    path = scenario!(Path.join(dir, "echo"), "echo_stdin\nout done\n")

    {:ok, _, pid} =
      :exec.run([Fake.executable(), "--scenario", path], [
        {:cd, String.to_charlist(dir)},
        :stdin,
        :stdout,
        :monitor,
        {:group, 0},
        :kill_group
      ])

    :exec.send(pid, "input\n")
    :exec.send(pid, :eof)
    assert_receive {:stdout, ^pid, data}, 1_000
    assert data =~ "input"
  end

  defp root_entries do
    [@repo_root, File.cwd!()]
    |> Enum.uniq()
    |> Map.new(fn root -> {root, MapSet.new(File.ls!(root))} end)
  end

  defp assert_root_entries_unchanged(before) do
    Enum.each(before, fn {root, entries_before} ->
      added = MapSet.difference(MapSet.new(File.ls!(root)), entries_before)
      assert MapSet.size(added) == 0, "new entries in #{root}: #{inspect(MapSet.to_list(added))}"
    end)
  end

  test "spawn_child and ignore_term commands keep group alive until KILL", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "child")

    path =
      scenario!(
        Path.join(dir, "child.scenario"),
        "ignore_term\nspawn_child\nout ready\nsleep 600\n"
      )

    {:ok, _, pid} =
      :exec.run(
        [Fake.executable(), "--scenario", path],
        [
          :stdout,
          {:group, 0},
          :kill_group,
          {:cd, String.to_charlist(dir)},
          {:env, [{"FAKE_CLI_CHILD_PID_FILE", pid_file}]}
        ]
      )

    on_exit(fn -> Exec.signal_group(pid, 9) end)
    assert_receive {:stdout, ^pid, "ready\n"}, 1_000
    eventually(fn -> File.exists?(pid_file) end)
    child = File.read!(pid_file) |> String.trim() |> String.to_integer()
    assert alive?(child)
    Exec.signal_group(pid, 15)
    Process.sleep(50)
    assert alive?(pid)
    Exec.signal_group(pid, 9)
    eventually(fn -> not alive?(pid) and not alive?(child) end)
  end
end
