defmodule Helmsman.Runs.EnqueueTest do
  use Helmsman.DataCase, async: true

  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Outcome, Run}
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{priority: :high})
    Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, task: task})
  end

  defp origin(scope, chain \\ []),
    do: %Origin{by_actor_id: scope.actor.id, initiator_user_id: scope.user.id, chain: chain}

  defp enqueue(origin, agent, task, trigger \\ %{kind: :assign, instructions: nil}) do
    agent = Repo.get!(Actor, agent.id)
    task = task && Repo.get!(Task, task.id)

    Tx.run(fn ->
      Runs.enqueue(origin, %{agent: agent, profile: profile(agent), task: task}, trigger)
    end)
  end

  defp set_profile(agent, changes),
    do: agent |> profile() |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp set_runtime(agent, changes),
    do:
      Runtime
      |> Repo.get!(profile(agent).runtime_id)
      |> Ecto.Changeset.change(changes)
      |> Repo.update!()

  defp now, do: DateTime.utc_now(:second)

  # {name, setup, origin (:alice | :bob), expected result, reason}
  @cases [
    {"owner, available", nil, :alice, :queued, nil},
    {"member, owner_only", nil, :bob, :skipped, :unauthorized},
    {"member, workspace access", {:profile, %{access: "workspace"}}, :bob, :queued, nil},
    {"disabled agent", {:actor, :disabled}, :alice, :skipped, :agent_disabled},
    {"archived agent", {:profile, :archived}, :alice, :skipped, :agent_archived},
    {"no runtime", {:profile, %{runtime_id: nil}}, :alice, :skipped, :no_runtime},
    {"disabled runtime", {:runtime, :disabled}, :alice, :skipped, :runtime_disabled},
    {"offline runtime", {:runtime, %{status: "offline"}}, :alice, :queued, nil},
    {"unauthorized before disabled runtime", {:runtime, :disabled}, :bob, :skipped, :unauthorized}
  ]

  for {name, change, who, result, reason} <- @cases do
    @change change
    test "#{name} → #{result} #{reason}", ctx do
      case @change do
        nil -> :ok
        {:profile, :archived} -> set_profile(ctx.agent, archived_at: now())
        {:profile, changes} -> set_profile(ctx.agent, changes)
        {:actor, :disabled} -> Repo.update!(Ecto.Changeset.change(ctx.agent, disabled_at: now()))
        {:runtime, :disabled} -> set_runtime(ctx.agent, disabled_at: now())
        {:runtime, changes} -> set_runtime(ctx.agent, changes)
      end

      scope = if unquote(who) == :alice, do: ctx.alice_scope, else: ctx.bob_scope
      assert {:ok, outcome} = enqueue(origin(scope), ctx.agent, ctx.task)

      assert %Outcome{agent: "keel/dev", trigger: :assign, result: unquote(result)} = outcome
      assert outcome.reason == unquote(reason)

      runs = runs_of(ctx.task.id)

      if unquote(result) == :queued do
        assert [%Run{id: id, status: :queued, lane: :work}] = runs
        assert outcome.run_id == id
      else
        assert runs == []
        assert outcome.run_id == nil
      end
    end
  end

  test "the run: initiator, chain, trigger, capabilities and priority", ctx do
    assert {:ok, %{result: :queued, run_id: id}} =
             enqueue(origin(ctx.alice_scope), ctx.agent, ctx.task, %{
               kind: :manual,
               instructions: "add tests"
             })

    run = Repo.get!(Run, id)
    assert run.root_initiator_user_id == ctx.alice.id
    assert run.causal_agent_ids == [ctx.agent.id]
    assert run.capabilities == ["read", "write_task"]
    assert run.priority == 3
    assert run.runtime_id == profile(ctx.agent).runtime_id

    assert [
             %{
               "kind" => "manual",
               "by_actor_id" => by,
               "initiator_user_id" => initiator,
               "causal_agent_ids" => chain,
               "instructions" => "add tests",
               "feedback_id" => nil,
               "at" => at
             }
           ] = run.triggers

    assert {by, initiator, chain} == {ctx.alice_scope.actor.id, ctx.alice.id, [ctx.agent.id]}
    assert {:ok, _, _} = DateTime.from_iso8601(at)
  end

  test "create_tasks adds the capability; no task: read only, priority 1", ctx do
    set_profile(ctx.agent, capabilities: ["create_tasks"])
    assert {:ok, %{run_id: id}} = enqueue(origin(ctx.alice_scope), ctx.agent, ctx.task)
    assert Repo.get!(Run, id).capabilities == ["read", "write_task", "create_tasks"]

    assert {:ok, %{result: :queued, run_id: id}} =
             enqueue(origin(ctx.alice_scope), ctx.agent, nil, %{kind: :manual, instructions: "x"})

    assert %Run{capabilities: ["read", "create_tasks"], priority: 1, task_id: nil} =
             Repo.get!(Run, id)
  end

  test "priority follows the task", ctx do
    for {priority, expected} <- [low: 1, medium: 2, high: 3] do
      task = task_fixture(ctx.alice_scope, ctx.project.key, %{priority: priority})
      {:ok, %{run_id: id}} = enqueue(origin(ctx.alice_scope), ctx.agent, task)
      assert Repo.get!(Run, id).priority == expected
    end
  end

  test "a trigger from a run passes on its initiator: borrowing an agent is refused", ctx do
    # bob triggered alice's workspace agent A; in its run A assigns alice's
    # owner_only agent keel/dev: the initiator is bob, not alice.
    a = agent_fixture(ctx.workspace, ctx.alice, "keel/a")
    run_origin = %Origin{by_actor_id: a.id, initiator_user_id: ctx.bob.id, chain: [a.id]}

    assert {:ok, %{result: :skipped, reason: :unauthorized}} =
             enqueue(run_origin, ctx.agent, ctx.task)

    assert runs_of(ctx.task.id) == []

    alice_origin = %{run_origin | initiator_user_id: ctx.alice.id}
    assert {:ok, %{result: :queued, run_id: id}} = enqueue(alice_origin, ctx.agent, ctx.task)
    assert Repo.get!(Run, id).causal_agent_ids == [a.id, ctx.agent.id]
  end

  describe "trigger chain" do
    setup ctx do
      others = for n <- 1..5, do: agent_fixture(ctx.workspace, ctx.alice, "keel/a#{n}")
      %{others: others}
    end

    test "A → B → A: loop_detected, with a system comment", ctx do
      [review | _] = ctx.others
      chain = [ctx.agent.id, review.id]
      origin = %Origin{by_actor_id: review.id, initiator_user_id: ctx.alice.id, chain: chain}

      assert {:ok, %{result: :skipped, reason: :loop_detected}} =
               enqueue(origin, ctx.agent, ctx.task)

      assert runs_of(ctx.task.id) == []

      assert [%Entry{kind: :comment, content: content, author_id: author_id}] =
               Repo.all(from(f in Entry, where: f.task_id == ^ctx.task.id))

      assert Repo.get!(Actor, author_id).name == "helmsman"
      assert content =~ "Did not start keel/dev: keel/dev is already in the trigger chain"
      assert content =~ "(keel/dev → keel/a1)"
      assert Repo.get!(Task, ctx.task.id).feedback_count == 1
    end

    test "more than 5 agents: chain_too_long, with a system comment", ctx do
      chain = Enum.map(ctx.others, & &1.id)

      origin = %Origin{
        by_actor_id: List.last(chain),
        initiator_user_id: ctx.alice.id,
        chain: chain
      }

      assert {:ok, %{result: :skipped, reason: :chain_too_long}} =
               enqueue(origin, ctx.agent, ctx.task)

      assert [%Entry{content: content}] =
               Repo.all(from(f in Entry, where: f.task_id == ^ctx.task.id))

      assert content =~ "the trigger chain is longer than 5 agents"
      assert content =~ "keel/a5 → keel/dev"
    end

    test "5 agents with the target is fine; no comment without a task", ctx do
      chain = ctx.others |> Enum.take(4) |> Enum.map(& &1.id)

      origin = %Origin{
        by_actor_id: List.last(chain),
        initiator_user_id: ctx.alice.id,
        chain: chain
      }

      assert {:ok, %{result: :queued}} = enqueue(origin, ctx.agent, ctx.task)

      loop = %{origin | chain: [ctx.agent.id]}

      assert {:ok, %{result: :skipped, reason: :loop_detected}} =
               enqueue(loop, ctx.agent, nil, %{kind: :manual, instructions: "x"})

      assert Repo.aggregate(Entry, :count) == 0
    end
  end
end
