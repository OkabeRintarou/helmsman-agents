defmodule Helmsman.Runs.SteeringSettleTest do
  # add-run-steering 1.5: settling the fallback triggers (decision 7) —
  # run-steering「结算」.
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Feedback, Runs}
  alias Helmsman.Runs.{Run, RunSteer, Steering}
  alias Helmsman.Runs.Workers.SideEffect
  alias Helmsman.Tasks.Task

  setup do
    ctx = dispatch_fixture(%{access: "workspace"})
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    s = running_run!(ctx.agent, %{task_id: task.id})
    Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, task: task, s: s})
  end

  # alice steers S: the fallback is queued in S's lane.
  defp steer!(ctx) do
    {:ok, entry} =
      Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "Steer", steer_run_id: ctx.s.id})

    [%{trigger: "steer", result: "queued", run_id: id}] = Feedback.view(entry).dispatch
    {entry, Repo.get!(Run, id)}
  end

  defp ack!(ctx, entry), do: :ok = Runs.steer_ack(dctx(ctx.agent), ctx.s.id, entry.id)

  defp end_s!(ctx, :succeeded), do: finish!(ctx.agent, ctx.s.id, :succeeded)

  # As the sweep judges an offline machine (scenario: 送达后失败).
  defp end_s!(ctx, :failed),
    do:
      set_run!(ctx.s.id,
        status: :failed,
        failure_reason: :runtime_offline,
        finished_at: DateTime.utc_now()
      )

  defp end_s!(ctx, :cancelled) do
    {:ok, _} = Runs.cancel(ctx.alice_scope, ctx.s.id)
    finish!(ctx.agent, ctx.s.id, :cancelled)
  end

  defp settle_job?(ctx),
    do: all_enqueued(worker: SideEffect, args: %{run_id: ctx.s.id, kind: "steer_settle"}) != []

  # Settles by the side effect (always run, even when not enqueued: it must
  # then change nothing) or by claiming.
  defp settle!(ctx, :side_effect) do
    assert {:ok, _} = Steering.settle(ctx.s.id)
    []
  end

  defp settle!(ctx, :claim), do: claim!(ctx.agent)

  describe "the table: S's end × receipt × where it settles" do
    for status <- [:succeeded, :failed, :cancelled],
        acked? <- [true, false],
        where <- [:side_effect, :claim] do
      @tag status: status, acked: acked?, where: where
      test "#{status}, acked: #{acked?}, by #{where}",
           %{status: status, acked: acked?, where: where} = ctx do
        {entry, fallback} = steer!(ctx)
        if acked?, do: ack!(ctx, entry)
        end_s!(ctx, status)

        assert settle_job?(ctx) == (status == :succeeded and acked?)
        claimed = settle!(ctx, where)
        run = Repo.reload!(fallback)

        if status == :succeeded and acked? do
          assert %Run{status: :cancelled, failure_reason: :obsolete} = run
          assert run.error =~ "steering delivered to run #{ctx.s.id}"
          assert claimed == []
        else
          assert [%{"kind" => "steer"}] = run.triggers

          if where == :claim,
            do: assert({run.status, claimed} == {:claimed, [run.id]}),
            else: assert(run.status == :queued)
        end
      end
    end
  end

  test "the side effect job settles (scenario: delivered, then succeeded)", ctx do
    {entry, fallback} = steer!(ctx)
    ack!(ctx, entry)
    end_s!(ctx, :succeeded)

    assert :ok = perform_job(SideEffect, %{run_id: ctx.s.id, kind: "steer_settle"})
    assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.reload!(fallback)
    assert claim!(ctx.agent) == []

    # Idempotent.
    assert :ok = perform_job(SideEffect, %{run_id: ctx.s.id, kind: "steer_settle"})
  end

  describe "partly settled runs" do
    setup ctx do
      {entry, fallback} = steer!(ctx)
      ack!(ctx, entry)
      end_s!(ctx, :succeeded)
      Map.merge(ctx, %{entry: entry, fallback: fallback})
    end

    test "bob's mention stays; the source becomes bob (scenario)", ctx do
      mention = trigger("mention", ctx.workspace, ctx.bob, ctx.agent)
      triggers = ctx.fallback.triggers ++ [mention]
      set_run!(ctx.fallback.id, triggers: triggers)

      assert {:ok, 1} = Steering.settle(ctx.s.id)

      assert %Run{status: :queued, triggers: [%{"kind" => "mention"}]} =
               run = Repo.reload!(ctx.fallback)

      assert run.root_initiator_user_id == ctx.bob.id
      assert run.causal_agent_ids == [ctx.agent.id]
    end

    test "by claiming: pruned and claimed with bob as the source", ctx do
      mention = trigger("mention", ctx.workspace, ctx.bob, ctx.agent)
      set_run!(ctx.fallback.id, triggers: ctx.fallback.triggers ++ [mention])

      assert [id] = claim!(ctx.agent)
      assert id == ctx.fallback.id

      assert %Run{status: :claimed, triggers: [%{"kind" => "mention"}]} =
               run = Repo.reload!(ctx.fallback)

      assert run.root_initiator_user_id == ctx.bob.id
    end

    test "an automatic retry marker alone is not enough to keep the run", ctx do
      retry = %{"kind" => "retry", "auto" => true, "retry_of" => 1}
      set_run!(ctx.fallback.id, triggers: [retry | ctx.fallback.triggers])

      assert {:ok, 1} = Steering.settle(ctx.s.id)
      assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.reload!(ctx.fallback)
    end

    test "only an assignment left after reassignment (scenario)", ctx do
      assign = trigger("assign", ctx.workspace, ctx.alice, ctx.agent)
      set_run!(ctx.fallback.id, triggers: [assign | ctx.fallback.triggers])
      bob_actor = human_actor(ctx.workspace, ctx.bob)

      Repo.update_all(from(t in Task, where: t.id == ^ctx.task.id),
        set: [assignee_id: bob_actor.id]
      )

      assert claim!(ctx.agent) == []
      assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.reload!(ctx.fallback)
    end

    test "starting checks the same way", ctx do
      daemon = daemon_of(ctx.agent)

      set_run!(ctx.fallback.id,
        status: :claimed,
        daemon_id: daemon.id,
        claimed_at: DateTime.utc_now()
      )

      assert {:ok, {:abort, "obsolete"}} = Runs.starting(dctx(ctx.agent), ctx.fallback.id)
      run = Repo.reload!(ctx.fallback)
      assert %Run{status: :failed, failure_reason: :obsolete} = run
      assert run.error =~ "steering delivered to run #{ctx.s.id}"
    end
  end

  test "a receipt of another feedback record does not settle this one", ctx do
    {_entry, fallback} = steer!(ctx)
    {:ok, other} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "unrelated"})

    Repo.insert!(%RunSteer{
      workspace_id: ctx.workspace.id,
      run_id: ctx.s.id,
      feedback_id: other.id,
      sent_at: DateTime.utc_now(),
      acked_at: DateTime.utc_now()
    })

    end_s!(ctx, :succeeded)
    assert {:ok, 0} = Steering.settle(ctx.s.id)
    assert [id] = claim!(ctx.agent)
    assert id == fallback.id
  end

  describe "settled?/2" do
    test "only a succeeded run with a receipt" do
      t = %{"steer_run_id" => 7, "feedback_id" => 31}
      at = DateTime.utc_now()

      assert Steering.settled?(t, %{{7, 31} => %{status: :succeeded, acked_at: at}})
      refute Steering.settled?(t, %{{7, 31} => %{status: :succeeded, acked_at: nil}})
      refute Steering.settled?(t, %{{7, 31} => %{status: :failed, acked_at: at}})
      refute Steering.settled?(t, %{{7, 31} => %{status: :running, acked_at: at}})
      refute Steering.settled?(t, %{})

      refute Steering.settled?(%{"feedback_id" => 31}, %{
               {7, 31} => %{status: :succeeded, acked_at: at}
             })
    end
  end
end
