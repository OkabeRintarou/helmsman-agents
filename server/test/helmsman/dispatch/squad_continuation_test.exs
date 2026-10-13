defmodule Helmsman.Dispatch.SquadContinuationTest do
  # add-squads 2.2: continuations of a squad's work (squad-dispatch "leader
  # 身份的延续"; run-dispatch "回调提出方", "回答触发"; decisions 6, 10).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Agents, Feedback, Runs, Squads, Tasks, Tx}
  alias Helmsman.Runs.{Outcome, Retry, Run}
  alias Helmsman.Tasks.{Task, TaskEvent}

  setup do
    ctx = squads_fixture()
    # carol may trigger every member.
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/qa", %{access: "workspace"})
    ctx
  end

  ## Helpers

  defp new_task(ctx, attrs \\ %{}), do: task_fixture(ctx.alice_scope, ctx.project.key, attrs)

  defp set_status(task, status),
    do: Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [status: status])

  defp settle(task) do
    Tx.run(fn ->
      {:ok, Runs.cancel_pending(from(r in Run, where: r.task_id == ^task.id), :obsolete)}
    end)
  end

  defp to_squad(ctx, task) do
    {:ok, task} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "web-team"})
    settle(task)
    task
  end

  defp run_scope(agent, task, attrs) do
    run =
      run_fixture(
        agent,
        Map.merge(
          %{task_id: task && task.id, status: :running, capabilities: ["read", "write_task"]},
          attrs
        )
      )

    {scope, _token} = run_scope_fixture(run)
    {scope, run}
  end

  defp leader_scope(ctx, task, attrs \\ %{}) do
    run_scope(
      ctx.lead,
      task,
      Map.merge(
        %{
          squad_id: ctx.squad.id,
          root_initiator_user_id: ctx.alice.id,
          capabilities: ["read", "write_task", "create_tasks", "delegate"],
          triggers: [
            trigger("assign", ctx.workspace, ctx.alice, ctx.lead, %{"squad_id" => ctx.squad.id})
          ]
        },
        attrs
      )
    )
  end

  defp delegated_scope(ctx, task) do
    run_scope(ctx.fe, task, %{
      root_initiator_user_id: ctx.alice.id,
      causal_agent_ids: [ctx.lead.id, ctx.fe.id],
      triggers: [
        trigger("delegated", ctx.workspace, ctx.alice, ctx.fe, %{
          "squad_id" => ctx.squad.id,
          "causal_agent_ids" => [ctx.lead.id, ctx.fe.id]
        })
      ]
    })
  end

  defp queued(task, agent) do
    Repo.all(
      from(r in Run,
        where: r.task_id == ^task.id and r.agent_id == ^agent.id and r.status == :queued
      )
    )
  end

  defp question(scope, task, text \\ "Which colour?") do
    {:ok, entry} = Feedback.add(scope, task.ident, %{kind: :question, content: text})
    entry
  end

  defp answer(scope, task), do: Feedback.add(scope, task.ident, %{kind: :answer, content: "Blue"})

  defp answer_trigger(task, agent) do
    [%Run{triggers: triggers}] = queued(task, agent)
    Enum.find(triggers, &(&1["kind"] == "answer"))
  end

  describe "reopen and resubmit" do
    test "a squad's task sent back: the leader as the squad, from the squad's grant", ctx do
      task = ctx |> to_squad(new_task(ctx)) |> tap(&set_status(&1, :done))
      carol = human_actor(ctx.workspace, ctx.carol).id

      {:ok, %{dispatch: [outcome]}} = Tasks.transition(ctx.carol_scope, task.ident, :in_progress)

      assert %Outcome{agent: "keel/lead", squad: "web-team", trigger: :reopen, result: :queued} =
               outcome

      assert [%Run{squad_id: squad_id, root_initiator_user_id: initiator, triggers: [trigger]}] =
               queued(task, ctx.lead)

      assert squad_id == ctx.squad.id
      assert initiator == ctx.alice.id
      assert %{"kind" => "reopen", "by_actor_id" => ^carol} = trigger
    end

    test "after the leader changed: the new leader", ctx do
      lead2 =
        managed_agent_fixture(ctx.alice_scope, %{
          name: "keel/lead2",
          runtime_id: ctx.runtime_id,
          access: "workspace"
        })

      task = ctx |> to_squad(new_task(ctx)) |> tap(&set_status(&1, :done))
      {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/lead2"})

      {:ok, %{dispatch: [%Outcome{agent: "keel/lead2", squad: "web-team", result: :queued}]}} =
        Tasks.transition(ctx.carol_scope, task.ident, :in_progress)

      assert [%Run{squad_id: squad_id}] = queued(task, agent_actor(ctx.workspace, lead2.name))
      assert squad_id == ctx.squad.id
    end

    test "the leader itself causes it: nothing", ctx do
      task = ctx |> to_squad(new_task(ctx)) |> tap(&set_status(&1, :done))
      {scope, _run} = leader_scope(ctx, task)

      assert {:ok, %{dispatch: []}} = Tasks.transition(scope, task.ident, :in_progress)
    end

    test "a disabled squad: skipped", ctx do
      task = ctx |> to_squad(new_task(ctx)) |> tap(&set_status(&1, :done))
      {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")

      assert {:ok, %{dispatch: [%Outcome{result: :skipped, reason: :squad_disabled}]}} =
               Tasks.transition(ctx.carol_scope, task.ident, :in_progress)
    end

    test "no grant of the squad: no_grant", ctx do
      task = new_task(ctx)

      Repo.update_all(from(t in Task, where: t.id == ^task.id),
        set: [assignee_id: ctx.squad_actor.id, status: :done]
      )

      assert {:ok, %{dispatch: [%Outcome{squad: "web-team", reason: :no_grant}]}} =
               Tasks.transition(ctx.carol_scope, task.ident, :in_progress)
    end

    test "resubmitted: the leader as the squad", ctx do
      task = ctx |> to_squad(new_task(ctx)) |> tap(&set_status(&1, :rejected))

      assert {:ok,
              %{dispatch: [%Outcome{trigger: :resubmit, squad: "web-team", result: :queued}]}} =
               Tasks.transition(ctx.alice_scope, task.ident, :new)
    end

    test "CI failed: reopened automatically, the leader as the squad", ctx do
      task = ctx |> to_squad(new_task(ctx)) |> tap(&set_status(&1, :verified))

      event =
        Repo.insert!(%TaskEvent{
          workspace_id: task.workspace_id,
          task_id: task.id,
          from_status: :done,
          to_status: :verified,
          actor_id: human_actor(ctx.workspace, ctx.carol).id,
          commits: []
        })

      assert {:ok, %{dispatch: [%Outcome{trigger: :reopen, squad: "web-team", result: :queued}]}} =
               Tasks.auto_reopen(task.id, %{
                 verification_event_id: event.id,
                 reason: :ci_failed,
                 content: "CI failed"
               })

      assert [%Run{squad_id: squad_id}] = queued(task, ctx.lead)
      assert squad_id == ctx.squad.id
    end
  end

  describe "answers" do
    test "a delegated member's question: the member, not as the squad, bound to the squad", ctx do
      task = to_squad(ctx, new_task(ctx))
      {scope, _run} = delegated_scope(ctx, task)
      question(scope, task)

      assert {:ok, entry} = answer(ctx.alice_scope, task)
      assert [%{agent: "keel/fe", result: "queued"}] = Feedback.view(entry).dispatch
      assert [%Run{squad_id: nil, capabilities: caps}] = queued(task, ctx.fe)
      refute "delegate" in caps

      assert %{"bound_assignee_id" => bound, "assignee_bound" => true} =
               answer_trigger(task, ctx.fe)

      assert bound == ctx.squad_actor.id
    end

    test "the bound assignee recorded by the question's run", ctx do
      # A leader run: the squad.
      task = to_squad(ctx, new_task(ctx))
      {scope, _run} = leader_scope(ctx, task)
      question(scope, task)
      {:ok, entry} = answer(ctx.alice_scope, task)
      assert [%{squad: "web-team"}] = Feedback.view(entry).dispatch
      assert answer_trigger(task, ctx.lead)["bound_assignee_id"] == ctx.squad_actor.id
      assert [%Run{squad_id: squad_id}] = queued(task, ctx.lead)
      assert squad_id == ctx.squad.id

      # An assignment of an agent: the agent.
      task = new_task(ctx, %{assignee: "keel/dev"})
      settle(task)

      {scope, _run} =
        run_scope(ctx.agent, task, %{
          triggers: [trigger("assign", ctx.workspace, ctx.alice, ctx.agent)]
        })

      question(scope, task)
      {:ok, _} = answer(ctx.alice_scope, task)
      assert answer_trigger(task, ctx.agent)["bound_assignee_id"] == ctx.agent.id

      # A manual or mention run: not bound.
      for kind <- ["manual", "mention"] do
        task = new_task(ctx, %{assignee: "keel/dev"})
        settle(task)

        {scope, _run} =
          run_scope(ctx.agent, task, %{
            triggers: [trigger(kind, ctx.workspace, ctx.alice, ctx.agent)]
          })

        question(scope, task)
        {:ok, _} = answer(ctx.alice_scope, task)
        trigger = answer_trigger(task, ctx.agent)
        refute Map.has_key?(trigger, "bound_assignee_id")
        assert trigger["assignee_bound"] == false
      end
    end

    test "older answers bound without an ID are bound to the run's agent", _ctx do
      triggers = [%{"kind" => "answer", "assignee_bound" => true}]

      assert Runs.Triggers.run_bound(%{triggers: triggers, agent_id: 7, squad_id: 3}) ==
               {:actor, 7}
    end
  end

  describe "callbacks to the requester" do
    test "a subtask the leader created is done: the leader as the squad", ctx do
      parent = to_squad(ctx, new_task(ctx))
      {scope, _run} = leader_scope(ctx, parent)

      {:ok, sub} = Tasks.create(scope, ctx.project.key, %{title: "Sub", assignee: "keel/fe"})
      settle(sub)
      {fe_scope, _run} = run_scope(ctx.fe, sub, %{})
      {:ok, _} = Tasks.transition(fe_scope, sub.ident, :in_progress)

      assert {:ok, %{dispatch: [outcome]}} = Tasks.transition(fe_scope, sub.ident, :done)
      assert %Outcome{agent: "keel/lead", squad: "web-team", trigger: :requested} = outcome

      assert [%Run{squad_id: squad_id, triggers: [%{"kind" => "requested"}]}] =
               queued(sub, ctx.lead)

      assert squad_id == ctx.squad.id
    end

    test "a member of the assignee squad asks: the requester is called back", ctx do
      pm = managed_agent_fixture(ctx.alice_scope, %{name: "keel/pm", access: "workspace"})
      pm = agent_actor(ctx.workspace, pm.name)
      {pm_scope, _run} = run_scope(pm, nil, %{capabilities: ["read", "create_tasks"]})

      {:ok, task} =
        Tasks.create(pm_scope, ctx.project.key, %{title: "For the squad", assignee: "web-team"})

      settle(task)
      {scope, _run} = delegated_scope(ctx, task)
      entry = question(scope, task)

      assert [%{agent: "keel/pm", trigger: "requested", result: "queued"}] =
               Feedback.view(entry).dispatch

      assert [%Run{triggers: [%{"kind" => "requested", "event" => "question"}]}] =
               queued(task, pm)
    end
  end

  describe "steering and retries" do
    test "steering a leader run needs the right to trigger the squad", ctx do
      task = to_squad(ctx, new_task(ctx))
      {:ok, _} = Agents.update(ctx.alice_scope, "keel/qa", %{access: "owner_only"})
      {_scope, run} = leader_scope(ctx, task, %{daemon_id: daemon_of(ctx.lead).id})

      assert {:ok, entry} =
               Feedback.add(ctx.bob_scope, task.ident, %{content: "Stop", steer_run_id: run.id})

      assert [
               %{
                 agent: "keel/lead",
                 trigger: "steer",
                 squad: "web-team",
                 result: "skipped",
                 reason: "unauthorized",
                 refused: ["keel/qa"]
               }
             ] = Feedback.view(entry).dispatch
    end

    test "a retry runs as the same squad", ctx do
      task = to_squad(ctx, new_task(ctx))

      failed =
        run_fixture(ctx.lead, %{
          task_id: task.id,
          status: :failed,
          failure_reason: :runtime_offline,
          squad_id: ctx.squad.id,
          finished_at: DateTime.utc_now(),
          triggers: [
            trigger("assign", ctx.workspace, ctx.alice, ctx.lead, %{"squad_id" => ctx.squad.id})
          ]
        })

      assert {:ok, :retried} = Retry.perform(failed.id)
      assert [%Run{squad_id: squad_id, retry_of_id: retry_of}] = queued(task, ctx.lead)
      assert {squad_id, retry_of} == {ctx.squad.id, failed.id}
    end
  end
end
