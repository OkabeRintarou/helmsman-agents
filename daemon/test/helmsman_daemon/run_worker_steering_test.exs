defmodule HelmsmanDaemon.RunWorkerSteeringTest do
  # add-run-steering 2.4: forwarding steering to the CLI and acknowledging
  # it (decision 9) — daemon-runner「插话转发与回执」, with the fake CLI.
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir

  # The fake adapter, telling the test about every `steer/3` call.
  defmodule Probe do
    @moduledoc false
    alias HelmsmanDaemon.Adapters.Fake
    defdelegate prepare(spec, run_dir, work_dir), to: Fake
    defdelegate init_state(spec), to: Fake
    defdelegate handle_output(stream, line, state), to: Fake
    defdelegate finish(status, state), to: Fake
    defdelegate interrupt(state), to: Fake

    def steer(ref, text, state) do
      send(Application.fetch_env!(:helmsman_daemon, :steer_probe), {:steer_called, ref, text})
      Fake.steer(ref, text, state)
    end
  end

  @unsupported "This CLI cannot take input while it runs; the message is queued for a run after this one"

  setup do
    start_execution()
    Application.put_env(:helmsman_daemon, :steer_probe, self())
    on_exit(fn -> Application.delete_env(:helmsman_daemon, :steer_probe) end)
    :ok
  end

  defp start(id, dir, script, mode \\ nil) do
    path = scenario!(Path.join(dir, "steer-#{id}"), script)
    run = spec(id)
    run = %{run | agent: %{run.agent | custom_args: [path | List.wrap(mode)]}}
    {:ok, worker} = Runs.start_run(run, reporter: TestReporter, adapter: Probe)
    assert_receive {:report, ^id, %Report.Started{}, _, _, _}, 2_000
    worker
  end

  # Every report of run `id` until `finished` (or the worker went away).
  defp reports(id, worker, acc \\ []) do
    ref = Process.monitor(worker)
    collect(id, ref, acc)
  end

  defp collect(id, ref, acc) do
    receive do
      {:report, ^id, %Report.Finished{} = finished, _, _, _} ->
        Enum.reverse([finished | acc])

      {:report, ^id, payload, _, _, _} ->
        collect(id, ref, [payload | acc])

      {:DOWN, ^ref, _, _, _} ->
        Enum.reverse(acc)
    after
      5_000 -> flunk("no finished report: #{inspect(Enum.reverse(acc))}")
    end
  end

  defp acks(reports), do: for(%Report.SteerAck{} = ack <- reports, do: ack)

  defp statuses(reports),
    do:
      for(
        %Report.Events{events: events} <- reports,
        %{type: :status, data: data} <- events,
        do: {data.level, data.message}
      )

  test "delivered (scenario): written to the CLI and acknowledged before finished",
       %{tmp_dir: dir} do
    worker = start(1, dir, "await_steer\nresult_steered\n", "delivered")
    Runs.steer(1, 31, "Use API B")

    reports = reports(1, worker)
    assert_received {:steer_called, 31, "Use API B"}
    assert [%Report.SteerAck{run_id: 1, feedback_id: 31}] = acks(reports)
    assert %Report.Finished{status: :succeeded, summary: summary} = List.last(reports)
    assert summary =~ "steered: Use API B"
  end

  # code-review-3 P2-1: quotes, backslashes and lines round-trip through the
  # fake CLI's result.
  test "steering text with quotes, backslashes and lines comes back intact", %{tmp_dir: dir} do
    text = ~S(Use the "README" file) <> "\n" <> ~S(and C:\tmp\x, not \n)
    worker = start(11, dir, "await_steer\nawait_steer\nresult_steered\n", "delivered")
    Runs.steer(11, 31, text)
    Runs.steer(11, 32, "second")

    reports = reports(11, worker)
    assert [%Report.SteerAck{feedback_id: 31}, %Report.SteerAck{feedback_id: 32}] = acks(reports)
    assert %Report.Finished{status: :succeeded, summary: summary} = List.last(reports)
    assert summary == "done; steered: " <> text <> " | second"
  end

  test "pending: acknowledged on the CLI's confirmation; repeats while pending are ignored",
       %{tmp_dir: dir} do
    worker = start(2, dir, "sleep 0.3\nawait_steer\nresult_steered\n", "pending")
    Runs.steer(2, 31, "first")
    Runs.steer(2, 31, "first")

    reports = reports(2, worker)
    assert_received {:steer_called, 31, "first"}
    refute_received {:steer_called, 31, _}
    assert [%Report.SteerAck{feedback_id: 31}] = acks(reports)
    assert {:info, "steer delivered"} in statuses(reports)
    assert %Report.Finished{status: :succeeded} = List.last(reports)
  end

  test "pushed again after delivery (scenario): only acknowledged again", %{tmp_dir: dir} do
    worker = start(3, dir, "await_steer\nsleep 0.4\nresult_steered\n", "delivered")
    Runs.steer(3, 31, "once")
    assert_receive {:report, 3, %Report.SteerAck{feedback_id: 31}, _, _, _}, 2_000
    Runs.steer(3, 31, "once")

    reports = reports(3, worker)
    assert [%Report.SteerAck{feedback_id: 31}] = acks(reports)
    assert_received {:steer_called, 31, "once"}
    refute_received {:steer_called, 31, _}
    assert %Report.Finished{summary: summary} = List.last(reports)
    refute summary =~ "once | once"
  end

  test "rejected: a warning, no receipt; a later push writes it again", %{tmp_dir: dir} do
    worker =
      start(4, dir, "reject_steer no active turn\nawait_steer\nresult_steered\n", "pending")

    Runs.steer(4, 31, "again")
    assert_receive {:steer_called, 31, "again"}, 2_000
    assert_receive {:report, 4, %Report.Events{events: events}, _, _, _}, 2_000

    assert Enum.any?(
             events,
             &(&1.type == :status and &1.data.message == "steer rejected: no active turn")
           )

    Runs.steer(4, 31, "again")
    reports = reports(4, worker)
    assert_received {:steer_called, 31, "again"}
    assert [%Report.SteerAck{feedback_id: 31}] = acks(reports)
    assert %Report.Finished{status: :succeeded, summary: summary} = List.last(reports)
    assert summary =~ "steered: again"
  end

  test "unsupported (scenario): no write, no receipt, one status note per record",
       %{tmp_dir: dir} do
    worker =
      start(
        5,
        dir,
        "sleep 0.5\njson {\"type\":\"result\",\"data\":{\"text\":\"ok\",\"success\":true}}\n"
      )

    Runs.steer(5, 31, "x")
    Runs.steer(5, 31, "x")
    Runs.steer(5, 32, "y")

    reports = reports(5, worker)
    assert acks(reports) == []
    assert Enum.count(statuses(reports), &(&1 == {:info, @unsupported})) == 2
    assert %Report.Finished{status: :succeeded} = List.last(reports)
  end

  test "still preparing (scenario): ignored, no receipt" do
    TestReporter.configure(fn
      %Report.Starting{} -> :hold
      other -> TestReporter.default(other)
    end)

    {:ok, worker} = Runs.start_run(spec(6), reporter: TestReporter, adapter: Probe)
    assert_receive {:report, 6, %Report.Starting{}, _, _, _}, 2_000
    Runs.steer(6, 31, "early")
    :sys.get_state(worker)
    refute_received {:steer_called, _, _}
    refute_receive {:report, 6, %Report.SteerAck{}, _, _, _}, 100
    Runs.terminate(6)
  end

  test "after a stop was asked for: ignored", %{tmp_dir: dir} do
    worker = start(7, dir, "sleep 1\n", "delivered")
    Runs.cancel(7)
    Runs.steer(7, 31, "late")

    reports = reports(7, worker)
    refute_received {:steer_called, _, _}
    assert acks(reports) == []
    assert %Report.Finished{status: :cancelled} = List.last(reports)
  end

  test "finished waits for the steer_ack reply (scenario)", %{tmp_dir: dir} do
    TestReporter.configure(fn
      %Report.SteerAck{} -> :hold
      other -> TestReporter.default(other)
    end)

    start(8, dir, "await_steer\nresult_steered\n", "delivered")
    Runs.steer(8, 31, "hold me")
    assert_receive {:report, 8, %Report.SteerAck{}, caller, ref, _}, 2_000
    refute_receive {:report, 8, %Report.Finished{}, _, _, _}, 500

    send(caller, {:report_result, ref, {:ok, %Reply.Empty{}}})
    assert_receive {:report, 8, %Report.Finished{status: :succeeded}, _, _, _}, 2_000
  end

  test "still pending when the CLI exits: no receipt is made up", %{tmp_dir: dir} do
    worker =
      start(
        9,
        dir,
        "sleep 0.3\njson {\"type\":\"result\",\"data\":{\"text\":\"ok\",\"success\":true}}\n",
        "pending"
      )

    Runs.steer(9, 31, "never confirmed")
    reports = reports(9, worker)
    assert_received {:steer_called, 31, _}
    assert acks(reports) == []
    assert %Report.Finished{status: :succeeded} = List.last(reports)
  end

  test "steer_ack answered wrong_state: the CLI is stopped, no finished", %{tmp_dir: dir} do
    TestReporter.configure(fn
      %Report.SteerAck{} -> {:error, %{reason: :wrong_state}}
      other -> TestReporter.default(other)
    end)

    worker = start(10, dir, "await_steer\nsleep 5\nresult_steered\n", "delivered")
    ref = Process.monitor(worker)
    Runs.steer(10, 31, "too late")
    assert_receive {:report, 10, %Report.SteerAck{}, _, _, _}, 2_000
    assert_receive {:DOWN, ^ref, _, _, :normal}, 5_000
    refute_received {:report, 10, %Report.Finished{}, _, _, _}
  end

  test "a run that is not here is ignored" do
    assert Runs.steer(404, 31, "nobody") == :ok
    refute_receive {:steer_called, _, _}, 50
  end
end
