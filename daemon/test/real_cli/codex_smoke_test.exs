defmodule HelmsmanDaemon.CodexSmokeTest do
  use HelmsmanDaemon.Case
  @moduletag :real_cli
  @moduletag :tmp_dir
  @moduletag timeout: 300_000
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Config
  alias HelmsmanDaemon.{Env, ProviderHTTP, RunWorker}

  setup do
    {url, stop} = ProviderHTTP.start(self(), :account, "SMOKE_SENTINEL")
    on_exit(stop)

    File.write!(Path.join(Config.home(), "config.toml"), """
    model_provider = "fake_gateway"
    [model_providers.fake_gateway]
    name = "Loopback smoke"
    base_url = "#{url}/account/v1"
    wire_api = "responses"
    env_key = "TEST_GATEWAY_KEY"
    """)

    start_execution()
    {:ok, env: Map.put(Env.child(), "TEST_GATEWAY_KEY", "SMOKE_SENTINEL")}
  end

  test "real Codex succeeds, resumes and stops in a git worktree without rewriting config", %{
    env: env,
    tmp_dir: dir
  } do
    assert {:ok, _} = Codex.detect()
    run = spec(10)

    run = %{
      run
      | prompt: "Reply with exactly OK",
        agent: %{
          run.agent
          | provider: :codex,
            model: "account-model",
            effort: "low",
            custom_args: []
        },
        limits: %{run.limits | timeout_ms: 120_000, idle_timeout_ms: 120_000}
    }

    # Preserve bytes and timestamp as a real user-home copy would. The provider
    # remains loopback-only; this test never reads the developer's Codex home.
    config = Path.join(Config.home(), "config.toml")
    copy = Path.join(dir, "config-copy.toml")
    File.touch!(config, {{2020, 1, 1}, {0, 0, 0}})
    assert {_, 0} = System.cmd("cp", ["-p", config, copy])
    File.chmod!(copy, 0o600)
    File.rename!(copy, config)
    snapshot = {File.read!(config), File.stat!(config).mtime}

    repo = Path.join(dir, "repo")
    cwd = Path.join([Paths.home(), "scratch", run.workspace.slug, run.task.ident])
    File.mkdir_p!(Path.dirname(cwd))
    git!(nil, ["init", "-q", repo])

    git!(repo, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@invalid",
      "commit",
      "--allow-empty",
      "-qm",
      "initial"
    ])

    git!(repo, ["worktree", "add", "-qb", "task", cwd])

    {first, _} = execute(run, env)
    assert first.status == :succeeded
    assert is_binary(first.session_id) and first.session_id != ""
    assert first.summary =~ "OK"
    assert_config_unchanged(config, snapshot)

    {second, _} =
      execute(
        %{
          run
          | run_id: 11,
            resume_session_id: first.session_id,
            prompt: "What did you reply last time?"
        },
        env
      )

    assert second.status == :succeeded
    assert second.session_id == first.session_id
    assert second.summary =~ "OK"
    assert_config_unchanged(config, snapshot)

    {cancelled, _} =
      execute(%{run | run_id: 13, prompt: "Run sleep 30, then reply DONE."}, env, true)

    assert cancelled.status == :cancelled
    assert_config_unchanged(config, snapshot)
  end

  defp git!(cwd, args) do
    options = if cwd, do: [cd: cwd, stderr_to_stdout: true], else: [stderr_to_stdout: true]
    {output, status} = System.cmd("git", args, options)
    assert status == 0, output
  end

  defp assert_config_unchanged(path, {bytes, mtime}) do
    # Boolean assertions avoid printing config (provider headers/keys) on failure.
    same_content? = File.read!(path) == bytes
    same_mtime? = File.stat!(path).mtime == mtime
    assert same_content?, "Codex changed config.toml contents"
    assert same_mtime?, "Codex changed config.toml modification time"
  end

  defp execute(run, env, stop? \\ false) do
    worker =
      start_supervised!(
        {RunWorker, {run, [adapter: Codex, reporter: TestReporter, base_env: env]}}
      )

    monitor = Process.monitor(worker)

    eventually(fn -> is_integer(:sys.get_state(worker).pgid) end)
    pgid = :sys.get_state(worker).pgid

    if stop? do
      # Wait for app-server output so this exercises a running CLI cancellation,
      # rather than deleting an empty run directory before its first output.
      eventually(fn -> File.exists?(Path.join(Paths.run(run.run_id), "raw.log")) end, 1_000)
      GenServer.cast(worker, {:stop, :cancel})
    end

    {finished, events} = collect(run.run_id, [], if(stop?, do: 10_000, else: 120_000))
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    assert File.ls!(Paths.run(run.run_id)) == ["raw.log"]
    refute File.exists?(Paths.record(run.run_id))
    {_, status} = System.cmd("kill", ["-0", "--", "-#{pgid}"], stderr_to_stdout: true)
    assert status != 0
    stop_supervised(RunWorker)
    {finished, events}
  end

  defp collect(id, events, timeout) do
    receive do
      {:report, ^id, %Report.Events{events: next}, _, _, _} ->
        collect(id, events ++ next, timeout)

      {:report, ^id, %Report.Finished{} = finished, _, _, _} ->
        {finished, events}

      {:report, ^id, _, _, _, _} ->
        collect(id, events, timeout)
    after
      timeout -> flunk("real Codex did not finish")
    end
  end
end
