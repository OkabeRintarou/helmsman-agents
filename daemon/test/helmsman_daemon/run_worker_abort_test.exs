defmodule HelmsmanDaemon.RunWorkerAbortTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.{AbortFake, ClaudeReplay}
  alias HelmsmanDaemon.RunWorker
  alias HelmsmanProtocol.{FailureReason, ProviderAccount}

  setup do
    start_execution()
    :ok
  end

  test "abort ignores other actions, preserves raw log and kills the CLI group", %{tmp_dir: dir} do
    scenario =
      scenario!(
        Path.join(dir, "abort"),
        "ignore_term\nout first\nout abort\nout later\nawait_stdin_eof\nout eof was delivered\nsleep 600\n"
      )

    run = %{spec(1, scenario) | prompt: "cli_error"}
    {finished, events} = execute(run, AbortFake)
    assert finished.status == :failed
    assert finished.failure_reason == :cli_error
    assert finished.error == "stop now"
    assert Enum.filter(events, &(&1.type == :text)) |> Enum.map(& &1.data.text) == ["first"]
    raw = File.read!(Path.join(Paths.run(1), "raw.log"))
    assert raw == "first\nabort\nlater\n"
  end

  test "cancel, timeout or stalled before adapter abort keeps the original conclusion", %{
    tmp_dir: dir
  } do
    for {id, reason, status} <- [
          {1, :cancel, :cancelled},
          {2, :timeout, :failed},
          {3, :stalled, :failed}
        ] do
      scenario =
        scenario!(Path.join(dir, "previous-#{id}"), "ignore_term\nout ready\necho_stdin\n")

      run = %{spec(id, scenario) | prompt: "cli_error"}

      worker =
        start_supervised!(
          {RunWorker, {run, [adapter: AbortFake, reporter: TestReporter, kill_timeout_ms: 400]}}
        )

      monitor = Process.monitor(worker)
      assert_receive {:report, ^id, %Report.Started{}, _, _, _}

      eventually(fn ->
        File.read(Path.join(Paths.run(id), "raw.log")) == {:ok, "ready\ncli_error\n"}
      end)

      GenServer.cast(worker, {:stop, reason})
      eventually(fn -> :sys.get_state(worker).stop_reason == reason end)
      pgid = :sys.get_state(worker).pgid
      send(worker, {:stdout, pgid, "abort\n"})
      eventually(fn -> :sys.get_state(worker).adapter_aborted? end)
      {finished, _} = collect(id, [])
      assert finished.status == status
      assert finished.failure_reason == if(reason == :cancel, do: nil, else: reason)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
      stop_supervised(RunWorker)
    end
  end

  test "server-only reasons are rejected at runtime and excluded from adapter action type", %{
    tmp_dir: dir
  } do
    assert {:ok, [{:attribute, _, :type, {:daemon_failure, type, []}} | _]} =
             :beam_lib.chunks(:code.which(HelmsmanDaemon.Adapter), [:abstract_code])
             |> adapter_types()

    assert type_atoms(type) |> Enum.sort() == Enum.sort(FailureReason.daemon_reportable())

    for {reason, id} <- Enum.with_index(FailureReason.server_only(), 1) do
      scenario = scenario!(Path.join(dir, "invalid-#{id}"), "out abort\nawait_stdin_eof\n")
      {finished, _} = execute(%{spec(id, scenario) | prompt: Atom.to_string(reason)}, AbortFake)
      assert finished.failure_reason == :cli_error
      assert finished.error == "Adapter returned an invalid abort reason or message"
    end
  end

  test "Claude helper ignored then success output cannot produce events or persist account key",
       %{tmp_dir: dir} do
    init =
      JSON.encode!(%{
        "type" => "system",
        "subtype" => "init",
        "session_id" => "session",
        "apiKeySource" => "none"
      })

    scenario =
      scenario!(
        Path.join(dir, "claude-guard"),
        "ignore_term\njson " <>
          init <>
          "\njson {\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"later\"}]}}\njson {\"type\":\"result\",\"is_error\":false,\"result\":\"success\"}\nawait_stdin_eof\nout stdin closed\n"
      )

    run = spec(1, scenario)

    run = %{
      run
      | agent: %{
          run.agent
          | provider_account: %ProviderAccount{
              base_url: "https://account.example",
              api_key: "ACCOUNT_SENTINEL",
              models: %{}
            }
        }
    }

    {finished, events} = execute(run, ClaudeReplay)
    assert finished.failure_reason == :cli_error
    assert finished.error =~ "none"
    refute Enum.any?(events, &(&1.type in [:text, :result]))
    raw = File.read!(Path.join(Paths.run(1), "raw.log"))
    assert raw =~ "success"
    refute raw =~ "stdin closed"

    for path <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        File.regular?(path),
        do: refute(File.read!(path) =~ "ACCOUNT_SENTINEL")

    assert File.ls!(Paths.run(1)) == ["raw.log"]
  end

  defp adapter_types({:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}}) do
    {:ok, Enum.filter(forms, &match?({:attribute, _, :type, {:daemon_failure, _, []}}, &1))}
  end

  defp type_atoms({:type, _, :union, types}), do: Enum.flat_map(types, &type_atoms/1)
  defp type_atoms({:atom, _, atom}), do: [atom]

  defp execute(run, adapter) do
    worker =
      start_supervised!(
        {RunWorker, {run, [adapter: adapter, reporter: TestReporter, kill_timeout_ms: 200]}}
      )

    monitor = Process.monitor(worker)
    {finished, events} = collect(run.run_id, [])
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    stop_supervised(RunWorker)
    {finished, events}
  end

  defp collect(id, events) do
    receive do
      {:report, ^id, %Report.Events{events: next}, _, _, _} -> collect(id, events ++ next)
      {:report, ^id, %Report.Finished{} = finished, _, _, _} -> {finished, events}
      {:report, ^id, _, _, _, _} -> collect(id, events)
    after
      5_000 -> flunk("abort run did not finish")
    end
  end
end
