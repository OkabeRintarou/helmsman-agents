defmodule Helmsman.Runs.SteeringSettleRaceTest do
  # add-run-steering 1.5: steer_settle against a claim and against a
  # feedback write, each on its own connection. A fallback run is never both
  # claimed and cancelled; neither side deadlocks or waits for long
  # (code-review-1 P2).
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures, only: [running_run!: 2, finish!: 3, dctx: 1]
  import Helmsman.RunsFixtures

  alias Helmsman.{CommittedData, Feedback, LockHarness, Repo, Runs}
  alias Helmsman.Runs.{Run, Steering}

  @base_url "http://localhost:4000"

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture()
        task = task_fixture(ctx.alice_scope, ctx.project.key)
        daemon = daemon_of(ctx.agent)

        s =
          run_fixture(ctx.agent, %{
            task_id: task.id,
            status: :running,
            daemon_id: daemon.id,
            claimed_at: DateTime.utc_now(),
            started_at: DateTime.utc_now()
          })

        {:ok, entry} =
          Feedback.add(ctx.alice_scope, task.ident, %{content: "Steer", steer_run_id: s.id})

        [%{run_id: fallback_id}] = Feedback.view(entry).dispatch
        :ok = Runs.steer_ack(daemon_ctx(daemon), s.id, entry.id)

        Repo.update_all(from(r in Run, where: r.id == ^s.id),
          set: [status: :succeeded, finished_at: DateTime.utc_now()]
        )

        Map.merge(ctx, %{s: s, fallback_id: fallback_id, dctx: daemon_ctx(daemon)})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  defp claim(ctx), do: fn -> Runs.claim(ctx.dctx, @base_url) end

  # `Steering.settle/1` opens a transaction per run: started on its own
  # connection, outside the harness's outer transaction. Options as
  # `LockHarness.start/2` (`pause: :settle_run`: after its first run).
  defp start_settle(run_id) do
    parent = self()

    task =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          send(parent, {:settle_backend, self(), CommittedData.backend_pid()})
          Steering.settle(run_id)
        end)
      end)

    assert_receive {:settle_backend, pid, backend}, 5_000
    %{task: task, pid: pid, backend: backend}
  end

  defp fallback(ctx), do: CommittedData.unboxed(fn -> Repo.get!(Run, ctx.fallback_id) end)

  defp assert_cancelled_once(ctx, claimed) do
    assert claimed == {:ok, []}
    assert %Run{status: :cancelled, failure_reason: :obsolete, daemon_id: nil} = fallback(ctx)
  end

  test "the claim stops before SKIP LOCKED while the settle commits", ctx do
    started = System.monotonic_time(:millisecond)
    claim = LockHarness.start(claim(ctx), pause: :claim_candidates)
    LockHarness.await_paused(claim)
    settle = start_settle(ctx.s.id)
    assert {:ok, 1} = LockHarness.result(settle)
    LockHarness.continue(claim)

    assert_cancelled_once(ctx, LockHarness.result(claim))
    assert System.monotonic_time(:millisecond) - started < 5_000
  end

  test "the claim holds the run row: the settle waits, then finds nothing pending", ctx do
    claim = LockHarness.start(claim(ctx), pause: :commit)
    LockHarness.await_paused(claim)
    settle = start_settle(ctx.s.id)
    LockHarness.await_blocked(settle)
    LockHarness.continue(claim)

    assert LockHarness.result(settle) == {:ok, 0}
    assert_cancelled_once(ctx, LockHarness.result(claim))
  end

  test "settle/1 refuses to run inside a transaction", ctx do
    assert_raise RuntimeError, ~r/must not run in a transaction/, fn ->
      CommittedData.unboxed(fn -> Repo.transaction(fn -> Steering.settle(ctx.s.id) end) end)
    end
  end
end

defmodule Helmsman.Runs.SteeringSettleLanesTest do
  # code-review-1 P2: S has a `reply` fallback (steered with a mention,
  # smaller ID) and a `work` one; an answer that mentions the agent locks
  # the `work` run, then the `reply` one, while steer_settle runs. Settling
  # one run per transaction holds one run row at a time: no cycle.
  use ExUnit.Case, async: false

  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures, only: [running_run!: 2, finish!: 3, dctx: 1]
  import Helmsman.RunsFixtures

  alias Helmsman.{CommittedData, Feedback, LockHarness, Repo, Runs}
  alias Helmsman.Runs.{Run, Steering}

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture()
        task = task_fixture(ctx.alice_scope, ctx.project.key)
        s = running_run!(ctx.agent, %{task_id: task.id, capabilities: ["read", "write_task"]})
        {scope, _token} = run_scope_fixture(s)
        {:ok, _q} = Feedback.add(scope, task.ident, %{kind: "question", content: "Which API?"})

        {:ok, reply} =
          Feedback.add(ctx.alice_scope, task.ident, %{
            content: "@keel/dev first",
            steer_run_id: s.id
          })

        {:ok, work} =
          Feedback.add(ctx.alice_scope, task.ident, %{content: "second", steer_run_id: s.id})

        [%{run_id: reply_id}] = Feedback.view(reply).dispatch
        [%{run_id: work_id}] = Feedback.view(work).dispatch
        :ok = Runs.steer_ack(dctx(ctx.agent), s.id, reply.id)
        :ok = Runs.steer_ack(dctx(ctx.agent), s.id, work.id)
        finish!(ctx.agent, s.id, :succeeded)
        Map.merge(ctx, %{task: task, s: s, reply_id: reply_id, work_id: work_id})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  # Pauses the writer right after it locked the pending `work` run.
  defp pause_after_work_lock(parent) do
    handler = "steering-lanes-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:helmsman, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if Process.get(:pause_after_work_lock) == true and meta.query =~ ~s("runs") and
               meta.query =~ "FOR UPDATE" and
               Enum.any?(meta.params || [], &(&1 in ["work", :work])) do
            Process.delete(:pause_after_work_lock)
            send(parent, {:writer_holds_work, self()})

            receive do
              :continue -> :ok
            after
              5_000 -> raise "barrier timeout"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "an answer mentioning the agent and steer_settle both complete", ctx do
    started = System.monotonic_time(:millisecond)
    assert CommittedData.unboxed(fn -> Repo.get!(Run, ctx.reply_id).lane end) == :reply
    assert ctx.reply_id < ctx.work_id
    pause_after_work_lock(self())

    writer =
      LockHarness.start(fn ->
        Process.put(:pause_after_work_lock, true)

        Feedback.add(ctx.alice_scope, ctx.task.ident, %{
          kind: "answer",
          content: "@keel/dev Use API B"
        })
      end)

    assert_receive {:writer_holds_work, writer_pid}, 5_000

    parent = self()

    settle =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          send(parent, {:settle_backend, CommittedData.backend_pid()})
          Steering.settle(ctx.s.id)
        end)
      end)

    assert_receive {:settle_backend, backend}, 5_000
    CommittedData.await_lock_wait(backend)
    send(writer_pid, :continue)

    assert {:ok, _entry} = LockHarness.result(writer)
    assert {:ok, 2} = Task.await(settle, 5_000)
    assert System.monotonic_time(:millisecond) - started < 5_000

    # Scenario「结算与跨 lane 的写入并发」: no settled trigger is left; the
    # answer is queued. The `reply` fallback had only the settled steer, so
    # it is cancelled; the mention of the same agent is `covered` by the
    # queued answer (add-nested-feedback-replies decision 12): no new
    # `reply` run.
    CommittedData.unboxed(fn ->
      runs = runs_of(ctx.task.id)
      queued = Enum.filter(runs, &(&1.status in Run.pending_statuses()))
      steer_marks = queued |> Enum.flat_map(& &1.triggers) |> Enum.map(& &1["steer_run_id"])

      assert Enum.uniq(steer_marks) == [nil]

      assert [%Run{lane: :work, triggers: [%{"kind" => "answer"}]}] = queued

      assert %Run{status: :queued} = Enum.find(runs, &(&1.id == ctx.work_id))

      assert %Run{status: :cancelled, failure_reason: :obsolete} =
               Enum.find(runs, &(&1.id == ctx.reply_id))
    end)
  end
end
