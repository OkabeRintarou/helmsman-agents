defmodule Helmsman.Dispatch.CancelPendingTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, Events, Members, Runtimes}
  alias Helmsman.Runs.Run
  alias Helmsman.Workspaces

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/other"})
    managed_agent_fixture(bob_scope, %{name: "bob/dev"})
    task = task_fixture(ctx.alice_scope, ctx.project.key)

    agents = %{
      dev: ctx.agent,
      other: agent_actor(ctx.workspace, "keel/other"),
      bob: agent_actor(ctx.workspace, "bob/dev")
    }

    runs =
      Map.new(agents, fn {key, agent} -> {key, run_fixture(agent, %{task_id: task.id})} end)

    claimed = run_fixture(ctx.agent, %{task_id: task.id, status: :claimed})
    Events.subscribe(Events.topic(:workspace_runs, ctx.workspace.id))

    Map.merge(ctx, %{
      bob: bob,
      bob_scope: bob_scope,
      task: task,
      agents: agents,
      runs: runs,
      claimed: claimed
    })
  end

  defp status(%Run{id: id}) do
    %Run{status: status, failure_reason: reason} = Repo.get!(Run, id)
    {status, reason}
  end

  # `claimed`: what becomes of keel/dev's claimed run (add-run-lifecycle
  # decision 15 stops it when the agent is disabled or archived).
  defp assert_only_cancelled(ctx, key, claimed \\ :claimed, reason \\ :obsolete) do
    id = ctx.runs[key].id
    text = Atom.to_string(reason)
    assert_receive {:run_updated, %{id: ^id, status: "cancelled", failure_reason: ^text}}
    assert status(ctx.runs[key]) == {:cancelled, reason}

    for {other, run} <- ctx.runs, other != key do
      assert status(run) == {:queued, nil}
    end

    assert status(ctx.claimed) == {claimed, nil}

    if claimed == :cancelling do
      claimed_id = ctx.claimed.id
      assert_receive {:run_updated, %{id: ^claimed_id, status: "cancelling"}}
    end

    refute_receive {:run_updated, _}
  end

  test "archiving an agent cancels its queued run", ctx do
    assert {:ok, _} = Agents.archive(ctx.alice_scope, "keel/dev")
    assert_only_cancelled(ctx, :dev, :cancelling)
  end

  test "disabling an agent cancels its queued run", ctx do
    assert {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")
    assert_only_cancelled(ctx, :dev, :cancelling)
  end

  test "unbinding the runtime cancels the queued run", ctx do
    assert {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{runtime_id: nil})
    assert_only_cancelled(ctx, :dev)
  end

  test "disabling the runtime cancels the queued runs on it", ctx do
    runtime_id = profile(ctx.agents.dev).runtime_id
    assert {:ok, _} = Runtimes.disable(ctx.alice_scope, runtime_id)
    assert_only_cancelled(ctx, :dev)
  end

  # bob authorized his agent's run too: `unauthorized` wins (add-run-lifecycle
  # decision 26).
  test "removing a member cancels their agents' queued runs", ctx do
    membership = Workspaces.get_membership(ctx.workspace.id, ctx.bob.id)
    assert {:ok, _} = Members.remove(ctx.alice_scope, membership.id)
    assert_only_cancelled(ctx, :bob, :claimed, :unauthorized)
  end

  test "rebinding moves the queued run to the new runtime and tells its daemon", ctx do
    {daemon, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
    runtime = runtime_fixture(ctx.workspace, daemon)
    Events.subscribe(Events.topic(:daemon, daemon.id))

    assert {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{runtime_id: runtime.id})

    id = ctx.runs.dev.id
    assert_receive {:run_updated, %{id: ^id, status: "queued"}}
    assert_receive {:runs_available}
    assert %Run{status: :queued, runtime_id: new} = Repo.get!(Run, id)
    assert new == runtime.id
    assert Repo.get!(Run, ctx.claimed.id).runtime_id != runtime.id
  end

  test "rebinding to a runtime of a revoked daemon does not tell it", ctx do
    {daemon, _token} =
      daemon_fixture(ctx.alice, %{
        workspace_ids: [ctx.workspace.id],
        revoked_at: DateTime.utc_now(:second)
      })

    runtime = runtime_fixture(ctx.workspace, daemon)
    Events.subscribe(Events.topic(:daemon, daemon.id))

    assert {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{runtime_id: runtime.id})
    assert_receive {:run_updated, _}
    refute_receive {:runs_available}
  end
end
