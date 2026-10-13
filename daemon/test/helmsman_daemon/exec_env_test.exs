defmodule HelmsmanDaemon.ExecEnvTest do
  use ExUnit.Case, async: false
  alias HelmsmanDaemon.{Env, Exec}

  setup do
    names =
      ~w(GIT_DIR HELMSMAN_HOME HELMSMAN_PROVIDER_API_KEY GIT_CONFIG_COUNT VSCODE_GIT_IPC_HANDLE)

    previous = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env(Map.new(names, &{&1, "cmd-sentinel"}))
    :ok
  end

  test "all launchers remove variables introduced after erlexec startup" do
    refute Map.has_key?(Env.child(), "GIT_DIR")
    assert {output, 0} = Env.cmd("env", [])
    assert_clean(output)
    assert {:ok, output} = Exec.command([System.find_executable("env")])
    assert_clean(output)
    assert {:ok, output} = Exec.version("env", args: [])
    assert_clean(output)
    options = [:stdout, :stderr, :monitor, {:group, 0}, :kill_group]
    assert {:ok, pid, os_pid, nil} = Exec.run_cli([System.find_executable("env")], options)
    assert_clean(collect(pid, os_pid, ""))
  end

  test "process query and signal launcher preserves daemon configuration only in BEAM" do
    assert {output, 0} = Env.cmd("env", [])
    assert_clean(output)
    assert output =~ "PATH="
    assert output =~ "HOME="
    assert System.get_env("HELMSMAN_HOME") == "cmd-sentinel"
    assert {output, 0} = Env.cmd("env", [], env: [{"GIT_DIR", "/explicit"}])
    assert output =~ "GIT_DIR=/explicit"
  end

  defp assert_clean(output) do
    for name <-
          ~w(GIT_DIR HELMSMAN_HOME HELMSMAN_PROVIDER_API_KEY GIT_CONFIG_COUNT VSCODE_GIT_IPC_HANDLE),
        do: refute(output =~ "#{name}=")

    refute output =~ "cmd-sentinel"
  end

  defp collect(pid, os_pid, output) do
    receive do
      {stream, ^os_pid, data} when stream in [:stdout, :stderr] ->
        collect(pid, os_pid, output <> data)

      {:DOWN, _, :process, ^pid, :normal} ->
        output
    after
      5_000 -> flunk("CLI environment command did not finish")
    end
  end
end
