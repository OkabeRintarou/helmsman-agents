defmodule Helmsman.Squads.OrchestrationCapabilityTest do
  # improve-squad-leader-orchestration 1.3: squad-orchestration 「编排能力」 and
  # squad-dispatch 「leader 运行的能力与开工」 (decision 3).
  use Helmsman.DataCase, async: true

  import Helmsman.OrchestrationFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, Repo, Runs, Tasks}
  alias Helmsman.Runs.Run

  setup do
    ctx = orchestration_fixture()
    # The leader's own run on the epic ends: claims are not held up by it.
    Repo.update_all(from(r in Run, where: r.status == :running), set: [status: :succeeded])
    ctx
  end

  # A queued callback run of the leader as the squad on `task`, queued
  # through `Runs.enqueue/3` (capabilities computed then).
  defp callback(ctx, task) do
    trigger = %{kind: :requested, instructions: nil, extra: %{"event" => "done"}}

    origin = %Runs.Origin{
      by_actor_id: ctx.fe.id,
      initiator_user_id: ctx.alice.id,
      chain: [ctx.fe.id]
    }

    target = %{
      agent: ctx.lead,
      profile: profile(ctx.lead),
      task: Repo.reload!(task),
      lane: :work,
      squad_id: ctx.squad.id
    }

    {:ok, {:ok, %{run_id: id}}} =
      Helmsman.Tx.run(fn -> {:ok, Runs.enqueue(origin, target, trigger)} end)

    Repo.get!(Run, id)
  end

  test "a callback run on a step: orchestrate when queued and when claimed", ctx do
    run = callback(ctx, ctx.s1)
    caps = ["read", "write_task", "create_tasks", "delegate", "orchestrate"]
    assert run.capabilities == caps
    assert [_] = claim!(ctx.lead)
    assert Repo.get!(Run, run.id).capabilities == caps
  end

  test "the root gone by the claim: no orchestrate, the run still claimed", ctx do
    run = callback(ctx, ctx.s1)
    assert "orchestrate" in run.capabilities

    {:ok, _} =
      Tasks.update(ctx.alice_scope, ctx.epic.ident, %{
        assignee: human_actor(ctx.workspace, ctx.carol).name
      })

    assert [_] = claim!(ctx.lead)
    assert %Run{status: :claimed, capabilities: caps} = Repo.get!(Run, run.id)
    refute "orchestrate" in caps
  end

  test "not as the squad: no orchestrate; the profile cannot grant it", ctx do
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/lead", %{capabilities: ["create_tasks"]})

    assert Runs.capabilities(profile(ctx.lead), Repo.reload!(ctx.s1), [], nil) == [
             "read",
             "write_task",
             "create_tasks"
           ]

    assert Runs.capabilities(profile(ctx.lead), nil, [], ctx.squad.id) == [
             "read",
             "create_tasks",
             "delegate"
           ]
  end

  test "a leader run on the squad's own task has it", ctx do
    {_scope, run} = leader_run(ctx, ctx.lead, ctx.epic)
    assert run.capabilities == ["read", "write_task", "create_tasks", "delegate", "orchestrate"]
  end
end
