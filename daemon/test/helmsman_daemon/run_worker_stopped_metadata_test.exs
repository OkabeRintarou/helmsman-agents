defmodule HelmsmanDaemon.RunWorkerStoppedMetadataTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.{Claude, Codex, Copilot, Fake}
  alias HelmsmanDaemon.RunWorker
  import ExUnit.CaptureLog

  defmodule StoppingReplay do
    def prepare(spec, dir, work) do
      {:ok, launch} = Fake.prepare(spec, dir, work)
      {:ok, %{launch | stdin: nil, close_stdin?: false}}
    end

    def init_state(spec),
      do: {adapter(spec.agent.provider), adapter(spec.agent.provider).init_state(spec)}

    def handle_output(stream, line, {adapter, state}) do
      {events, actions, state} = adapter.handle_output(stream, line, state)
      {events, actions, {adapter, state}}
    end

    def finish(code, {adapter, state}), do: adapter.finish(code, state)
    def interrupt(_), do: :signal
    defp adapter(:claude), do: Claude
    defp adapter(:codex), do: Codex
    defp adapter(:copilot), do: Copilot
  end

  defmodule CrashingFinish do
    defdelegate prepare(spec, dir, work), to: Fake
    defdelegate init_state(spec), to: Fake
    defdelegate handle_output(stream, line, state), to: Fake
    def interrupt(_), do: :signal
    def finish(_, _), do: raise("metadata failed")
  end

  setup do
    start_execution()
    :ok
  end

  for {provider, line} <- [
        {:claude, ~s({"type":"system","subtype":"init","session_id":"stopped-session"})},
        {:codex, ~s({"id":2,"result":{"thread":{"id":"stopped-session"}}})},
        {:copilot, ~s({"type":"session.start","data":{}})}
      ] do
    test "#{provider} stopped run preserves session and daemon outcome", %{tmp_dir: dir} do
      path = scenario!(Path.join(dir, "scenario"), "json " <> unquote(line) <> "\nsleep 30\n")
      run = spec(1, path)

      run = %{
        run
        | resume_session_id: "stopped-session",
          agent: %{run.agent | provider: unquote(provider)}
      }

      {:ok, worker} =
        RunWorker.start_link({run, [adapter: StoppingReplay, reporter: TestReporter]})

      ref = Process.monitor(worker)
      wait_session(1)
      GenServer.cast(worker, {:stop, :cancel})
      finished = wait_finished(1)
      assert finished.status == :cancelled and finished.failure_reason == nil
      assert finished.session_id == "stopped-session"
      assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 3000
    end
  end

  test "stopped run survives adapter finish exception and logs warning", %{tmp_dir: dir} do
    run =
      spec(
        2,
        scenario!(
          Path.join(dir, "crash"),
          "json {\"type\":\"session\",\"data\":{\"session_id\":\"known\"}}\nsleep 30\n"
        )
      )

    log =
      capture_log(fn ->
        {:ok, worker} =
          RunWorker.start_link({run, [adapter: CrashingFinish, reporter: TestReporter]})

        ref = Process.monitor(worker)
        assert_receive {:report, 2, %Report.Started{}, _, _, _}, 2000
        GenServer.cast(worker, {:stop, :timeout})
        finished = wait_finished(2)
        assert finished.status == :failed and finished.failure_reason == :timeout
        assert finished.session_id == nil and finished.summary == nil and finished.usage == nil
        assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 3000
      end)

    assert log =~ "could not finalize metadata"
  end

  defp wait_session(id) do
    receive do
      {:report, ^id, %Report.Events{events: events}, _, _, _} ->
        if Enum.any?(events, &(&1.type == :session)), do: :ok, else: wait_session(id)

      {:report, ^id, _, _, _, _} ->
        wait_session(id)
    after
      5000 -> flunk("session missing")
    end
  end

  defp wait_finished(id) do
    receive do
      {:report, ^id, %Report.Finished{} = finished, _, _, _} -> finished
      {:report, ^id, _, _, _, _} -> wait_finished(id)
    after
      5000 -> flunk("finished missing")
    end
  end
end
