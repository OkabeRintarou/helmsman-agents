defmodule Helmsman.Dispatch.SquadAssignTest do
  # add-squads 2.1: assigning and mentioning a squad, deferred leader runs
  # and merging by squad (squad-dispatch "指派给小队", "提及小队", "延后的
  # leader 运行"; run-dispatch "合并排队的触发").
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Agents, Dispatch, Feedback, Links, Squads, Tasks}
  alias Helmsman.Dispatch.Dependencies
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.{Outcome, Run, TaskGrant}
  alias Helmsman.Tasks.Task, as: TaskRow

  setup do
    ctx = squads_fixture()
    Map.put(ctx, :bos12, task_fixture(ctx.alice_scope, ctx.project.key))
  end

  defp assign(scope, task, name, extra \\ %{}),
    do: Tasks.update(scope, task.ident, Map.merge(%{assignee: name}, extra))

  defp pending(task),
    do: Enum.filter(runs_of(task.id), &(&1.status in [:queued, :deferred]))

  defp grants(task, actor),
    do: Repo.all(from(g in TaskGrant, where: g.task_id == ^task.id and g.agent_id == ^actor.id))

  describe "assigning a squad" do
    test "a leader run as the squad, with a grant of the squad", ctx do
      assert {:ok, %{dispatch: [outcome]}} = assign(ctx.alice_scope, ctx.bos12, "web-team")

      assert %Outcome{agent: "keel/lead", squad: "web-team", result: :queued, trigger: :assign} =
               outcome

      lead_id = ctx.lead.id
      squad_id = ctx.squad.id
      alice_id = ctx.alice.id

      assert [
               %Run{
                 agent_id: ^lead_id,
                 squad_id: ^squad_id,
                 status: :queued,
                 lane: :work,
                 root_initiator_user_id: ^alice_id,
                 triggers: [%{"kind" => "assign", "squad_id" => ^squad_id}],
                 capabilities: caps
               }
             ] = runs_of(ctx.bos12.id)

      assert caps == ["read", "write_task", "create_tasks", "delegate"]

      assert [%TaskGrant{kind: :assign, squad_id: ^squad_id, causal_agent_ids: []}] =
               grants(ctx.bos12, ctx.squad_actor)
    end

    test "a member blocks: saved, no run, no grant", ctx do
      assert {:ok, task} = assign(ctx.bob_scope, ctx.bos12, "web-team")
      assert task.assignee_id == ctx.squad_actor.id

      assert [
               %Outcome{
                 agent: "keel/lead",
                 squad: "web-team",
                 result: :skipped,
                 reason: :unauthorized,
                 refused: ["keel/qa"]
               }
             ] = task.dispatch

      assert runs_of(ctx.bos12.id) == []
      assert grants(ctx.bos12, ctx.squad_actor) == []
    end

    test "not started: a grant, no run", ctx do
      assert {:ok, %{dispatch: [%Outcome{result: :skipped, reason: :not_started}]}} =
               assign(ctx.alice_scope, ctx.bos12, "web-team", %{start: false})

      assert runs_of(ctx.bos12.id) == []
      assert [_] = grants(ctx.bos12, ctx.squad_actor)
    end

    test "the leader on the chain", ctx do
      run =
        run_fixture(ctx.lead, %{
          task_id: ctx.bos12.id,
          status: :running,
          squad_id: ctx.squad.id,
          root_initiator_user_id: ctx.alice.id,
          causal_agent_ids: [ctx.lead.id],
          capabilities: ["read", "write_task", "create_tasks", "delegate"]
        })

      {scope, _token} = run_scope_fixture(run)

      assert {:ok, task} =
               Tasks.create(scope, ctx.project.key, %{title: "Sub", assignee: "web-team"})

      assert [%Outcome{squad: "web-team", result: :skipped, reason: :loop_detected}] =
               task.dispatch

      assert [%Entry{kind: :comment, content: "Did not start keel/lead" <> _}] =
               Repo.all(from(f in Entry, where: f.task_id == ^task.id))

      assert grants(task, ctx.squad_actor) == []
    end

    # Decision 15.
    test "a disabled squad cannot be assigned", ctx do
      {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")
      assert {:error, %Ecto.Changeset{}} = assign(ctx.alice_scope, ctx.bos12, "web-team")
      assert runs_of(ctx.bos12.id) == []
    end

    test "the same agent as two identities is not merged", ctx do
      {:ok, _} = assign(ctx.alice_scope, ctx.bos12, "web-team")

      assert {:ok, %{outcome: %Outcome{result: :queued}}} =
               Dispatch.run_agent(ctx.carol_scope, "keel/lead", ctx.bos12.ident, "look")

      assert [%Run{squad_id: squad_id}, %Run{squad_id: nil}] = pending(ctx.bos12)
      assert squad_id == ctx.squad.id
    end

    test "run_agent refuses a squad", ctx do
      assert {:error, :is_squad} =
               Dispatch.run_agent(ctx.alice_scope, "web-team", ctx.bos12.ident, "go")
    end
  end

  describe "mentioning a squad" do
    test "a reply run of the leader as the squad", ctx do
      {:ok, _} = Agents.update(ctx.alice_scope, "keel/qa", %{access: "workspace"})

      assert {:ok, entry} =
               Feedback.add(ctx.carol_scope, ctx.bos12.ident, %{content: "@web-team 请评估一下"})

      assert [%{agent: "keel/lead", squad: "web-team", result: "queued"}] =
               Feedback.view(entry).dispatch

      carol = human_actor(ctx.workspace, ctx.carol).id

      assert [%Run{lane: :reply, squad_id: squad_id, triggers: [trigger]}] = pending(ctx.bos12)
      assert squad_id == ctx.squad.id
      assert %{"kind" => "mention", "by_actor_id" => ^carol} = trigger
    end

    test "not allowed to trigger a member", ctx do
      assert {:ok, entry} =
               Feedback.add(ctx.bob_scope, ctx.bos12.ident, %{content: "@web-team ?"})

      assert [
               %{
                 agent: "keel/lead",
                 squad: "web-team",
                 result: "skipped",
                 reason: "unauthorized",
                 refused: ["keel/qa"]
               }
             ] = Feedback.view(entry).dispatch

      assert pending(ctx.bos12) == []
    end

    test "the leader mentioning its squad triggers nothing", ctx do
      run =
        run_fixture(ctx.lead, %{
          task_id: ctx.bos12.id,
          status: :running,
          root_initiator_user_id: ctx.alice.id,
          capabilities: ["read", "write_task"]
        })

      {scope, _token} = run_scope_fixture(run)
      assert {:ok, entry} = Feedback.add(scope, ctx.bos12.ident, %{content: "@web-team done"})
      assert Feedback.view(entry).dispatch == []
    end

    test "the squad and its leader mentioned together: two runs", ctx do
      assert {:ok, entry} =
               Feedback.add(ctx.alice_scope, ctx.bos12.ident, %{
                 content: "@web-team and @keel/lead"
               })

      assert [_, _] = Feedback.view(entry).dispatch
      assert [%Run{}, %Run{}] = pending(ctx.bos12)
    end

    test "concurrent-looking mentions merge into the squad's run", ctx do
      {:ok, _} = Dispatch.run_agent(ctx.carol_scope, "keel/lead", ctx.bos12.ident, "look")
      {:ok, _} = Feedback.add(ctx.alice_scope, ctx.bos12.ident, %{content: "@web-team a"})
      {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.bos12.ident, %{content: "@web-team b"})

      assert [%{result: "merged"}] = Feedback.view(entry).dispatch

      squad_id = ctx.squad.id

      assert [
               %Run{squad_id: nil, lane: :work},
               %Run{squad_id: ^squad_id, lane: :reply, triggers: [_, _]}
             ] = pending(ctx.bos12)
    end
  end

  describe "deferred leader runs" do
    setup ctx do
      bos1 = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Links.add(ctx.alice_scope, ctx.bos12.ident, bos1.ident, "depends_on")
      Map.put(ctx, :bos1, bos1)
    end

    test "deferred, then queued when the dependency is done", ctx do
      assert {:ok, %{dispatch: [%Outcome{squad: "web-team", result: :deferred}]}} =
               assign(ctx.alice_scope, ctx.bos12, "web-team")

      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, :in_progress)
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, :done)
      {:ok, _} = Tasks.transition(ctx.carol_scope, ctx.bos1.ident, :verified)

      assert [%Run{status: :queued, squad_id: squad_id}] = runs_of(ctx.bos12.id)
      assert squad_id == ctx.squad.id
    end

    test "reassigned from the squad to an agent: cancelled", ctx do
      {:ok, _} = assign(ctx.alice_scope, ctx.bos12, "web-team")
      [deferred] = runs_of(ctx.bos12.id)
      assert deferred.status == :deferred

      {:ok, _} = assign(ctx.alice_scope, ctx.bos12, "keel/dev")

      assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, deferred.id)
    end

    test "the sweep keeps a deferred run of the squad that is still the assignee", ctx do
      {:ok, _} = assign(ctx.alice_scope, ctx.bos12, "web-team")
      [deferred] = runs_of(ctx.bos12.id)

      Dependencies.sweep()
      assert %Run{status: :deferred} = Repo.get!(Run, deferred.id)

      Repo.update_all(from(t in TaskRow, where: t.id == ^ctx.bos12.id),
        set: [assignee_id: ctx.lead.id]
      )

      Dependencies.sweep()
      assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, deferred.id)
    end
  end
end
