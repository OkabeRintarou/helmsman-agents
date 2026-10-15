defmodule Helmsman.TaskSpecs.WakeTest do
  # add-spec-workflow 2.3: spec-dispatch 「评审完成唤醒」「定稿决定唤醒」
  # (decision 11).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.{Repo, Squads, Tasks, TaskSpecs}
  alias Helmsman.Runs.{Run, TaskGrant}

  setup do
    ctx = specs_fixture()
    {lead, _} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})
    spec_fixture(ctx.alice_scope, ctx.task.ident)
    # The leader's assignment run is not part of these tests.
    Repo.delete_all(from(r in Run, where: r.status == :queued))

    Map.merge(ctx, %{
      ident: ctx.task.ident,
      lead_scope: lead,
      bob_name: human_actor(ctx.workspace, ctx.bob).name
    })
  end

  defp queued(agent),
    do: Repo.all(from(r in Run, where: r.agent_id == ^agent.id and r.status == :queued))

  defp review_as_bob(ctx) do
    TaskSpecs.submit_review(ctx.bob_scope, ctx.ident, %{
      version: 1,
      verdict: "fail",
      issues: [%{severity: "P1", body: "a"}, %{severity: "P3", body: "b"}]
    })
  end

  defp hook_seen do
    parent = self()

    Process.put(:helmsman_test_hook, fn
      {:dispatch_targets, round} -> send(parent, {:locked_targets, round})
      _other -> :ok
    end)
  end

  describe "评审完成唤醒" do
    test "a person member's review of the leader's request wakes the leader", ctx do
      {:ok, %{result: :requested}} =
        Squads.delegate(ctx.lead_scope, ctx.ident, ctx.bob_name, "Please review", "review")

      hook_seen()

      assert {:ok,
              %{review: 1, dispatch: %{result: :queued, target: "keel/lead", squad: "web-team"}}} =
               review_as_bob(ctx)

      # The targets were locked before the task and spec rows.
      assert_received {:locked_targets, 1}

      assert [%Run{squad_id: squad_id, root_initiator_user_id: initiator, triggers: [trigger]}] =
               queued(ctx.lead)

      assert {squad_id, initiator} == {ctx.squad.id, ctx.alice.id}
      bob = human_actor(ctx.workspace, ctx.bob).id

      assert %{
               "kind" => "spec_reviewed",
               "by_actor_id" => ^bob,
               "review" => 1,
               "version" => 1,
               "verdict" => "fail",
               "counts" => %{"P1" => 1, "P2" => 0, "P3" => 1}
             } = trigger
    end

    test "a request a person made wakes nobody", ctx do
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, [ctx.bob_name])
      assert {:ok, %{dispatch: nil}} = review_as_bob(ctx)
      assert queued(ctx.lead) == []
    end

    test "an agent's review wakes nobody (delegate_done does)", ctx do
      {:ok, _} = Squads.delegate(ctx.lead_scope, ctx.ident, "keel/review", "Review", "review")
      {review, _} = agent_run_scope(ctx.review, ctx.task)

      assert {:ok, %{dispatch: nil}} =
               TaskSpecs.submit_review(review, ctx.ident, %{version: 1, verdict: "pass"})
    end

    test "the squad disabled: skipped", ctx do
      {:ok, _} = Squads.delegate(ctx.lead_scope, ctx.ident, ctx.bob_name, "Review", "review")
      {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")

      assert {:ok, %{dispatch: %{result: :skipped, reason: :squad_disabled}}} = review_as_bob(ctx)
      assert queued(ctx.lead) == []
    end
  end

  describe "定稿决定唤醒" do
    test "approving wakes the leader as the squad", ctx do
      {:ok, _} = TaskSpecs.finalize(ctx.lead_scope, ctx.ident, %{version: 1, summary: "ok"})
      hook_seen()

      assert {:ok, %{decision: :approved, dispatch: %{result: :queued, squad: "web-team"}}} =
               TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 1})

      assert_received {:locked_targets, 1}

      assert [%Run{squad_id: squad_id, triggers: [%{"kind" => "spec_decided"} = trigger]}] =
               queued(ctx.lead)

      assert squad_id == ctx.squad.id
      assert %{"decision" => "approved", "version" => 1} = trigger
    end

    test "sending back with a reason; or without waking", ctx do
      {:ok, _} = TaskSpecs.finalize(ctx.lead_scope, ctx.ident, %{version: 1, summary: "ok"})

      assert {:ok, %{dispatch: nil, spec: %{status: :draft}}} =
               TaskSpecs.reject(ctx.alice_scope, ctx.ident, %{reason: "No", wake: false})

      assert queued(ctx.lead) == []

      {:ok, _} = TaskSpecs.finalize(ctx.lead_scope, ctx.ident, %{version: 1, summary: "ok"})
      hook_seen()

      assert {:ok, %{dispatch: %{result: :queued}}} =
               TaskSpecs.reject(ctx.alice_scope, ctx.ident, %{reason: "Add error states"})

      assert_received {:locked_targets, 1}

      assert [%Run{triggers: [%{"decision" => "rejected", "reason" => "Add error states"}]}] =
               queued(ctx.lead)
    end

    test "a managed agent assignee is woken itself", ctx do
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/dev"})
      spec_fixture(ctx.alice_scope, task.ident)
      Repo.delete_all(from(r in Run, where: r.status == :queued))

      assert {:ok,
              %{
                decision: :finalized,
                dispatch: %{result: :queued, target: "keel/dev", squad: nil}
              }} =
               TaskSpecs.finalize(ctx.alice_scope, task.ident, %{version: 1})

      assert [
               %Run{
                 lane: :work,
                 triggers: [%{"kind" => "spec_decided", "decision" => "finalized"}]
               }
             ] =
               queued(ctx.agent)
    end

    test "without the assignment's grant: skipped unauthorized", ctx do
      Repo.delete_all(from(g in TaskGrant, where: g.task_id == ^ctx.task.id))

      assert {:ok, %{dispatch: %{result: :skipped, reason: :unauthorized}}} =
               TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 1})

      assert queued(ctx.lead) == []
    end

    test "a closed task or a person assignee: nothing", ctx do
      {:ok, _} = Tasks.update(ctx.alice_scope, ctx.ident, %{assignee: ctx.bob_name})

      assert {:ok, %{dispatch: nil}} =
               TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 1})
    end

    test "reassigned while queued: obsolete when claimed", ctx do
      {:ok, %{dispatch: %{run_id: run_id}}} =
        TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 1})

      {:ok, _} = Tasks.update(ctx.alice_scope, ctx.ident, %{assignee: "keel/dev", start: false})

      Repo.update_all(from(r in Run, where: r.status == :running),
        set: [status: :succeeded, finished_at: DateTime.utc_now()]
      )

      claim!(ctx.lead)
      assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, run_id)
    end
  end
end
