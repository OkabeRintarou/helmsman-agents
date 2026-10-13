defmodule HelmsmanDaemon.RunWorkerEnvTest do
  use HelmsmanDaemon.Case
  alias HelmsmanDaemon.Env
  @moduletag :tmp_dir

  setup do
    start_execution()
    :ok
  end

  test "VS Code and Copilot inherited environment is scrubbed before CLI launch" do
    base = hostile_base()
    raw = run_cli(70, %{}, base)

    for name <- Map.keys(base),
        Env.child_drop?(name),
        name not in ~w(GIT_TERMINAL_PROMPT HELMSMAN_RUN_TOKEN HELMSMAN_SERVER_URL HELMSMAN_RUN_ID HELMSMAN_TASK),
        do: refute(raw =~ "#{name}=")

    refute raw =~ "hostile-sentinel"
    assert raw =~ "PATH=#{base["PATH"]}"
    assert raw =~ "SSH_AUTH_SOCK=/kept/socket"
    assert raw =~ "GITHUB_TOKEN=kept-token"
    assert raw =~ "GIT_TERMINAL_PROMPT=0"
    refute raw =~ "HELMSMAN_PROVIDER_API_KEY="
  end

  test "explicit Agent git settings override defaults after inherited cleanup" do
    raw =
      run_cli(
        71,
        %{"GIT_SSH_COMMAND" => "ssh -i /k", "GIT_TERMINAL_PROMPT" => "1"},
        hostile_base()
      )

    assert raw =~ "GIT_SSH_COMMAND=ssh -i /k"
    assert raw =~ "GIT_TERMINAL_PROMPT=1"
  end

  defp hostile_base do
    Map.merge(Map.take(System.get_env(), ~w(PATH HOME LANG)), %{
      "GIT_ASKPASS" => "",
      "SSH_ASKPASS" => "/hostile/askpass",
      "SSH_ASKPASS_REQUIRE" => "force",
      "GIT_CONFIG_COUNT" => "3",
      "GIT_CONFIG_KEY_0" => "safe.bareRepository",
      "GIT_CONFIG_VALUE_0" => "explicit",
      "GIT_CONFIG_KEY_1" => "credential.interactive",
      "GIT_CONFIG_VALUE_1" => "false",
      "GIT_CONFIG_KEY_2" => "core.fsmonitor",
      "GIT_CONFIG_VALUE_2" => "/hostile/fsmonitor",
      "GIT_TERMINAL_PROMPT" => "0",
      "VSCODE_GIT_IPC_HANDLE" => "/hostile/git.sock",
      "VSCODE_GIT_ASKPASS_NODE" => "/hostile/node",
      "VSCODE_IPC_HOOK_CLI" => "/hostile/code.sock",
      "HELMSMAN_PROVIDER_API_KEY" => "hostile-sentinel",
      "HELMSMAN_GIT_TOKEN" => "hostile-sentinel",
      "HELMSMAN_RUN_TOKEN" => "hostile-sentinel",
      "SSH_AUTH_SOCK" => "/kept/socket",
      "GITHUB_TOKEN" => "kept-token"
    })
  end

  defp run_cli(id, agent_env, base) do
    scenario =
      scenario!(
        Path.join(Paths.home(), "env-#{id}"),
        "dump_env\njson {\"type\":\"result\",\"data\":{\"text\":\"done\",\"success\":true}}\n"
      )

    run = spec(id, scenario)
    run = %{run | agent: %{run.agent | env: agent_env}}
    {:ok, worker} = Runs.start_run(run, reporter: TestReporter, base_env: base)
    monitor = Process.monitor(worker)
    assert_receive {:report, ^id, %Report.Finished{status: :succeeded}, _, _, _}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    File.read!(Path.join(Paths.run(id), "raw.log"))
  end
end
