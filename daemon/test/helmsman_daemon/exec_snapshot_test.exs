defmodule HelmsmanDaemon.ExecSnapshotTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  test "independent VM proves the snapshot and clears every Exec entry", %{tmp_dir: dir} do
    script = Path.join(dir, "snapshot.exs")

    File.write!(script, ~S"""
    alias HelmsmanDaemon.{Env, Exec}
    System.delete_env("GIT_DIR")
    System.delete_env("HELMSMAN_GIT_TOKEN")
    collect = fn collect, pid, os_pid, output ->
      receive do
        {stream, ^os_pid, data} when stream in [:stdout, :stderr] ->
          collect.(collect, pid, os_pid, output <> data)
        {:DOWN, _, :process, ^pid, :normal} -> output
      after
        5_000 -> raise "environment command did not finish"
      end
    end
    options = [:stdout, :stderr, :monitor, {:group, 0}, :kill_group]
    argv = [System.find_executable("env")]
    {:ok, pid, os_pid} = :exec.run(argv, options)
    control = collect.(collect, pid, os_pid, "")
    unless control =~ "GIT_DIR=/nonexistent/snapshot" and
           control =~ "HELMSMAN_GIT_TOKEN=snapshot-sentinel",
      do: raise("control did not inherit erlexec snapshot")
    clean = fn output ->
      if output =~ "GIT_DIR=" or output =~ "HELMSMAN_GIT_TOKEN=" or output =~ "snapshot-sentinel",
        do: raise("Exec inherited the startup snapshot")
    end
    {:ok, pid, os_pid, nil} = Exec.run_cli(argv, options)
    clean.(collect.(collect, pid, os_pid, ""))
    {:ok, pid, os_pid, guardian} = Exec.start_cli(argv, options)
    clean.(collect.(collect, pid, os_pid, ""))
    Exec.release_cli(guardian)
    {:ok, output} = Exec.command(argv, env: Enum.to_list(Env.child()))
    clean.(output)
    {:ok, output} = Exec.version("env", args: [])
    clean.(output)
    IO.puts("snapshot verified")
    """)

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", script],
        env: [
          {"MIX_ENV", "test"},
          {"GIT_DIR", "/nonexistent/snapshot"},
          {"HELMSMAN_GIT_TOKEN", "snapshot-sentinel"},
          {"ERL_FLAGS", "+S 2:2"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "snapshot verified"
  end
end
