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

  test "real Codex succeeds, resumes and stops with a loopback provider", %{env: env} do
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

    {first, _} = execute(run, env)
    assert first.status == :succeeded
    assert is_binary(first.session_id) and first.session_id != ""
    assert first.summary =~ "OK"

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

    {cancelled, _} =
      execute(%{run | run_id: 13, prompt: "Run sleep 30, then reply DONE."}, env, true)

    assert cancelled.status == :cancelled
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
