defmodule HelmsmanDaemon.EnvTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias HelmsmanDaemon.Env

  @dropped ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS
    GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_ASKPASS GIT_TERMINAL_PROMPT
    GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_EXEC_PATH GIT_SSH GIT_SSH_COMMAND
    GIT_EDITOR GIT_PAGER GIT_EXTERNAL_DIFF GIT_TRACE GIT_TRACE2 GIT_FUTURE
    SSH_ASKPASS SSH_ASKPASS_REQUIRE VSCODE_GIT_IPC_HANDLE VSCODE_GIT_ASKPASS_NODE
    VSCODE_GIT_ASKPASS_MAIN VSCODE_IPC_HOOK_CLI VSCODE_FUTURE)
  @kept ~w(PATH HOME USER SHELL LANG LC_ALL LC_FUTURE XDG_CONFIG_HOME XDG_FUTURE HTTP_PROXY
    HTTPS_PROXY NO_PROXY SSH_AUTH_SOCK DISPLAY NODE_EXTRA_CA_CERTS GH_TOKEN GITHUB_TOKEN
    ANTHROPIC_API_KEY OPENAI_API_KEY GIT git_dir vscode_ipc_hook_cli SSH_ASKPASS_OTHER)

  test "session variables are excluded by name and everything else is preserved" do
    for name <- @dropped, do: assert(Env.inherited_drop?(name))
    for name <- @kept, do: refute(Env.inherited_drop?(name))
    reserved = ~w(HELMSMAN_HOME HELMSMAN_PROVIDER_API_KEY HELMSMAN_GIT_TOKEN HELMSMAN_RUN_TOKEN)
    for name <- reserved, do: refute(Env.inherited_drop?(name))
    for name <- @dropped ++ reserved, do: assert(Env.child_drop?(name))
    base = Map.new(@dropped ++ @kept ++ reserved, &{&1, "value-of-#{&1}"})
    assert Env.child(base) == Map.take(base, @kept)
    assert Env.child(Enum.to_list(base)) == Map.take(base, @kept)
  end

  test "startup removes current session state and prints only sorted names" do
    names = ~w(GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 VSCODE_GIT_IPC_HANDLE)
    inherited = System.get_env() |> Map.keys() |> Enum.filter(&Env.inherited_drop?/1)

    previous =
      Map.new(Enum.uniq(names ++ inherited ++ ["HELMSMAN_HOME"]), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(inherited, &System.delete_env/1)
    System.put_env(Map.new(names, &{&1, "private-sentinel"}))
    System.put_env("HELMSMAN_HOME", "/home/daemon")

    assert capture_io(:stderr, fn -> assert Env.scrub_process!() == names end) ==
             "Ignoring inherited environment variables: #{Enum.join(names, ", ")}\n"

    for name <- names, do: assert(System.get_env(name) == nil)
    assert System.get_env("HELMSMAN_HOME") == "/home/daemon"
    assert capture_io(:stderr, fn -> assert Env.scrub_process!() == [] end) == ""
  end

  test "port helpers receive a scrubbed child environment" do
    names = ~w(GIT_CONFIG_COUNT HELMSMAN_HOME __BURRITO_TEST RELEASE_ROOT)
    previous = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env(Map.new(names, &{&1, "private-sentinel"}))
    port = Env.port(System.find_executable("env"), [], [{:line, 4096}])
    output = collect_port(port, "")
    refute output =~ "private-sentinel"
    assert output =~ "PATH="
  end

  defp collect_port(port, output) do
    receive do
      {^port, {:data, {:eol, line}}} -> collect_port(port, output <> line <> "\n")
      {^port, {:exit_status, 0}} -> output
    after
      1_000 -> flunk("environment helper did not exit")
    end
  end
end
