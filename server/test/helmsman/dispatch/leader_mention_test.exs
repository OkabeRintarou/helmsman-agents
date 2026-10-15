defmodule Helmsman.Dispatch.LeaderMentionTest do
  # improve-squad-leader-orchestration 3.1 / 3.2: squad-dispatch
  # 「对 leader 本人的提及与手动运行」 (decision 14).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Dispatch, Feedback, Runs, Squads, Tasks, Tx}
  alias Helmsman.Runs.Run

  setup do
    ctx = squads_fixture()
    epic = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: "epic", title: "Emulator"})
    {:ok, _} = Tasks.update(ctx.alice_scope, epic.ident, %{assignee: "web-team"})
    settle()
    Map.put(ctx, :epic, Repo.reload!(epic))
  end

  defp settle do
    Tx.run(fn -> {:ok, Runs.cancel_pending(from(r in Run), :obsolete)} end)
    :ok
  end

  defp step(ctx, attrs \\ %{}) do
    task = task_fixture(ctx.alice_scope, ctx.project.key, Map.put(attrs, :epic, ctx.epic.ident))
    settle()
    task
  end

  defp queued(task) do
    Repo.all(
      from(r in Run,
        where: r.task_id == ^task.id and r.status in [:queued, :deferred],
        order_by: r.id
      )
    )
  end

  defp squad_id(ctx), do: ctx.squad.id

  describe "mentions" do
    test "a person @leader on the squad's epic: a reply run as the squad", ctx do
      {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.epic.ident, %{content: "@keel/lead go on"})

      assert [%Run{agent_id: lead, lane: :reply, squad_id: squad_id, triggers: [trigger]}] =
               queued(ctx.epic)

      assert lead == ctx.lead.id
      assert squad_id == squad_id(ctx)

      assert %{"kind" => "mention", "as_leader" => true, "feedback_id" => feedback_id} = trigger
      assert feedback_id == entry.id
      refute Map.has_key?(trigger, "squad_refused")
    end

    test "on a step of the squad's epic: as the squad", ctx do
      step = step(ctx, %{assignee: "keel/fe"})
      {:ok, _} = Feedback.add(ctx.alice_scope, step.ident, %{content: "@keel/lead look"})

      assert [%Run{agent_id: lead, squad_id: squad_id, lane: :reply}] = queued(step)
      assert {lead, squad_id} == {ctx.lead.id, squad_id(ctx)}
    end

    test "a writer who may not trigger every member: the leader alone, with the refusal", ctx do
      # keel/qa is owner_only: carol may trigger keel/lead but not keel/qa.
      {:ok, _} = Feedback.add(ctx.carol_scope, ctx.epic.ident, %{content: "@keel/lead go"})

      assert [%Run{agent_id: lead, squad_id: nil, lane: :reply, triggers: [trigger]}] =
               queued(ctx.epic)

      assert lead == ctx.lead.id

      assert %{
               "squad_refused" => ["keel/qa"],
               "refused_squad" => "web-team",
               "squad_owner" => owner
             } = trigger

      assert owner == ctx.epic.ident
      refute trigger["as_leader"]
    end

    test "a task the squad has nothing to do with: the leader alone", ctx do
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: human_name(ctx, :carol)})
      settle()

      # keel/lead also leads docs-team, which owns another epic.
      squad_fixture(ctx.alice_scope, %{name: "docs-team", leader: "keel/lead"})
      {:ok, _} = Feedback.add(ctx.alice_scope, task.ident, %{content: "@keel/lead ?"})

      assert [%Run{squad_id: nil, triggers: [trigger]}] = queued(task)
      refute Map.has_key?(trigger, "squad_refused")
    end

    test "the task's own squad comes before its epic's", ctx do
      docs = squad_fixture(ctx.alice_scope, %{name: "docs-team", leader: "keel/lead"})
      step = step(ctx)
      {:ok, _} = Tasks.update(ctx.alice_scope, step.ident, %{assignee: "docs-team"})
      settle()

      {:ok, _} = Feedback.add(ctx.alice_scope, step.ident, %{content: "@keel/lead ?"})
      assert [%Run{squad_id: squad_id}] = queued(step)
      assert squad_id == docs.id
    end

    test "a disabled squad or another leader: not as the squad", ctx do
      managed_agent_fixture(ctx.alice_scope, %{
        name: "keel/lead2",
        runtime_id: ctx.runtime_id,
        access: "workspace"
      })

      {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/lead2"})
      {:ok, _} = Feedback.add(ctx.alice_scope, ctx.epic.ident, %{content: "@keel/lead ?"})
      assert [%Run{agent_id: lead, squad_id: nil}] = queued(ctx.epic)
      assert lead == ctx.lead.id
    end

    test "an agent in a run @leader: judged by that run's authorization source", ctx do
      step = step(ctx, %{assignee: "keel/fe"})

      for {user, squad} <- [{ctx.carol, nil}, {ctx.alice, squad_id(ctx)}] do
        run =
          run_fixture(ctx.fe, %{
            task_id: step.id,
            status: :running,
            capabilities: ["read", "write_task"],
            root_initiator_user_id: user.id
          })

        {scope, _token} = run_scope_fixture(run)
        {:ok, _} = Feedback.add(scope, step.ident, %{content: "@keel/lead help"})

        assert [%Run{agent_id: lead, squad_id: ^squad}] =
                 Enum.filter(queued(step), &(&1.agent_id == ctx.lead.id))

        assert lead == ctx.lead.id
        settle()
      end
    end

    test "@squad and @leader in one record: one run, two triggers", ctx do
      {:ok, _} =
        Feedback.add(ctx.alice_scope, ctx.epic.ident, %{content: "@web-team and @keel/lead"})

      assert [%Run{squad_id: squad_id, lane: :reply, triggers: triggers}] = queued(ctx.epic)
      assert squad_id == squad_id(ctx)
      assert [%{"kind" => "mention"}, %{"kind" => "mention"}] = triggers
      assert Enum.count(triggers, & &1["as_leader"]) == 1
    end
  end

  describe "manual runs" do
    test "a person starts the leader on the squad's epic: as the squad", ctx do
      assert {:ok, %{outcome: %{result: :queued}}} =
               Dispatch.run_agent(ctx.alice_scope, "keel/lead", ctx.epic.ident, "Carry on")

      assert [%Run{lane: :work, squad_id: squad_id, triggers: [trigger]}] = queued(ctx.epic)
      assert squad_id == squad_id(ctx)

      assert %{"kind" => "manual", "as_leader" => true, "instructions" => "Carry on"} = trigger
    end

    test "refused: the leader alone with the members in the way", ctx do
      assert {:ok, _} = Dispatch.run_agent(ctx.carol_scope, "keel/lead", ctx.epic.ident, nil)

      assert [%Run{squad_id: nil, triggers: [%{"squad_refused" => ["keel/qa"]}]}] =
               queued(ctx.epic)
    end

    test "no task, or a task the squad does not own: the leader alone", ctx do
      assert {:ok, _} = Dispatch.run_agent(ctx.alice_scope, "keel/lead", nil, "Look around")
      assert Repo.one(from(r in Run, where: is_nil(r.task_id), select: r.squad_id)) == nil

      task = task_fixture(ctx.alice_scope, ctx.project.key)
      assert {:ok, _} = Dispatch.run_agent(ctx.alice_scope, "keel/lead", task.ident, nil)
      assert [%Run{squad_id: nil}] = queued(task)
    end

    test "a run token still may not start agents", ctx do
      run = run_fixture(ctx.lead, %{task_id: ctx.epic.id, status: :running})
      {scope, _token} = run_scope_fixture(run)
      assert Dispatch.run_agent(scope, "keel/lead", ctx.epic.ident, "x") == {:error, :forbidden}
    end
  end

  test "a step assigned to the leader itself is not upgraded", ctx do
    step = step(ctx)
    {:ok, _} = Tasks.update(ctx.alice_scope, step.ident, %{assignee: "keel/lead"})

    assert [%Run{agent_id: lead, squad_id: nil, triggers: [%{"kind" => "assign"} = trigger]}] =
             queued(step)

    assert lead == ctx.lead.id
    refute trigger["as_leader"]
  end

  defp human_name(ctx, who), do: human_actor(ctx.workspace, Map.fetch!(ctx, who)).name
end
