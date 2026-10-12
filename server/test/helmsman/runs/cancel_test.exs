defmodule Helmsman.Runs.CancelTest do
  # add-run-lifecycle 4.1: stopping runs (decisions 15, 19).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, Events, Members, Runs, Workspaces}
  alias Helmsman.Runs.{Run, RunTokens}
  alias HelmsmanProtocol.Report

  setup do
    ctx = dispatch_fixture(%{access: "workspace"})
    daemon = daemon_of(ctx.agent)
    Events.subscribe(Events.topic(:daemon, daemon.id))
    Map.merge(ctx, %{daemon: daemon})
  end

  defp active(ctx, status, agent \\ nil) do
    run_fixture(agent || ctx.agent, %{
      status: status,
      daemon_id: ctx.daemon.id,
      claimed_at: DateTime.utc_now()
    })
  end

  defp reload(run), do: Repo.get!(Run, run.id)

  test "stopping a running run: cancelling, the daemon is told, cancelled once reported (scenario)",
       ctx do
    run = active(ctx, :running)
    {:ok, token} = RunTokens.issue(run)
    id = run.id

    assert {:ok, %{status: "cancelling", cancel_requested_by: %{name: _}}} =
             Runs.cancel(ctx.alice_scope, id)

    assert_receive {:cancel_run, ^id}
    assert reload(run).cancel_requested_by_id

    {:ok, report} = Report.Finished.new(%{run_id: id, status: :succeeded, summary: "Stopped."})
    assert Runs.finish(daemon_ctx(ctx.daemon), report) == :ok
    assert %Run{status: :cancelled, failure_reason: nil} = reload(run)
    assert RunTokens.authenticate(token) == {:error, :unauthorized}

    # Stopping a cancelling run is fine; an ended one is not.
    assert {:error, :already_finished} = Runs.cancel(ctx.alice_scope, id)
  end

  test "a queued run is cancelled at once; cancelling stays as it is", ctx do
    queued = run_fixture(ctx.agent)

    assert {:ok, %{status: "cancelled", finished_at: %DateTime{}}} =
             Runs.cancel(ctx.alice_scope, queued.id)

    refute_receive {:cancel_run, _}

    cancelling = active(ctx, :cancelling)
    assert {:ok, %{status: "cancelling"}} = Runs.cancel(ctx.alice_scope, cancelling.id)
    refute_receive {:cancel_run, _}
  end

  test "who may stop: the source, the agent's owner, admins; not others (scenario)", ctx do
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {_carol, carol_scope} = member_scope_fixture(ctx.workspace)
    {_dave, admin_scope} = member_scope_fixture(ctx.workspace, :admin)
    {_erin, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)

    by_bob = run_fixture(ctx.agent, %{root_initiator_user_id: bob.id})
    assert {:error, :forbidden} = Runs.cancel(carol_scope, by_bob.id)
    assert {:error, :forbidden} = Runs.cancel(viewer_scope, by_bob.id)
    assert {:ok, _} = Runs.cancel(bob_scope, by_bob.id)

    for scope <- [ctx.alice_scope, admin_scope] do
      run = run_fixture(ctx.agent, %{root_initiator_user_id: bob.id})
      assert {:ok, _} = Runs.cancel(scope, run.id)
    end

    assert {:error, :not_found} = Runs.cancel(ctx.alice_scope, 999_999_999)
  end

  test "a run token may not stop runs", ctx do
    run = active(ctx, :running)
    {scope, _token} = run_scope_fixture(run)
    assert {:error, :forbidden} = Runs.cancel(scope, run.id)
    assert reload(run).status == :running
  end

  for {name, fun} <- [
        {"disabling", &Agents.disable/2},
        {"archiving", &Agents.archive/2}
      ] do
    @fun fun
    test "#{name} the agent stops its active runs", ctx do
      claimed = active(ctx, :claimed)
      running = active(ctx, :running)
      queued = run_fixture(ctx.agent)

      assert {:ok, _} = @fun.(ctx.alice_scope, "keel/dev")

      for run <- [claimed, running] do
        id = run.id

        assert %Run{status: :cancelling, failure_reason: nil, cancel_requested_by_id: nil} =
                 reload(run)

        assert_receive {:cancel_run, ^id}
      end

      assert %Run{status: :cancelled, failure_reason: :obsolete} = reload(queued)
    end
  end

  test "removing the agent's owner stops its active runs", ctx do
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(bob_scope, %{name: "bob/dev"})
    agent = agent_actor(ctx.workspace, "bob/dev")
    bob_daemon = daemon_of(agent)
    Events.subscribe(Events.topic(:daemon, bob_daemon.id))

    # Authorized by alice, so it is stopped as bob's agent's run.
    run =
      run_fixture(agent, %{
        status: :running,
        daemon_id: bob_daemon.id,
        root_initiator_user_id: ctx.alice.id
      })

    membership = Workspaces.get_membership(ctx.workspace.id, bob.id)
    assert {:ok, _} = Members.remove(ctx.alice_scope, membership.id)

    id = run.id
    assert %Run{status: :cancelling, failure_reason: nil} = reload(run)
    assert_receive {:cancel_run, ^id}
  end
end
