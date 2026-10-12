defmodule Helmsman.Runs.InitiatorRemovedTest do
  # add-run-lifecycle 4.1a: removing (or the leaving of) a run's
  # authorization source stops the runs they authorized (decision 26).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Daemons.Daemon
  alias Helmsman.{Events, Members, Runs, Workspaces}
  alias Helmsman.Runs.Run
  alias Helmsman.Runs.Workers.{Retry, Sweep}
  alias HelmsmanProtocol.Report

  setup do
    ctx = dispatch_fixture(%{access: "workspace"})
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {carol, _carol_scope} = member_scope_fixture(ctx.workspace)
    daemon = daemon_of(ctx.agent)
    Events.subscribe(Events.topic(:daemon, daemon.id))
    Events.subscribe(Events.topic(:workspace_runs, ctx.workspace.id))

    Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, carol: carol, daemon: daemon})
  end

  defp by(ctx, user, agent, attrs) do
    run_fixture(
      agent,
      Map.merge(
        %{
          triggers: [trigger("manual", ctx.workspace, user, agent)],
          root_initiator_user_id: user.id
        },
        attrs
      )
    )
  end

  defp active(ctx, user, agent, status, daemon) do
    by(ctx, user, agent, %{status: status, daemon_id: daemon.id, claimed_at: DateTime.utc_now()})
  end

  defp reload(run), do: Repo.get!(Run, run.id)
  defp remove(ctx, user), do: Members.remove(ctx.alice_scope, membership_id(ctx, user))
  defp membership_id(ctx, user), do: Workspaces.get_membership(ctx.workspace.id, user.id).id

  defp updates do
    receive do
      {:run_updated, %{id: id}} -> [id | updates()]
    after
      100 -> []
    end
  end

  test "bob is removed: his runs on alice's agent stop, unauthorized, no retry (scenario)", ctx do
    running = active(ctx, ctx.bob, ctx.agent, :running, ctx.daemon)

    queued =
      by(ctx, ctx.bob, ctx.agent, %{
        triggers: [
          trigger("assign", ctx.workspace, ctx.bob, ctx.agent),
          trigger("manual", ctx.workspace, ctx.carol, ctx.agent)
        ]
      })

    deferred = by(ctx, ctx.bob, ctx.agent, %{})
    Repo.update_all(from(r in Run, where: r.id == ^deferred.id), set: [status: :deferred])
    alices = by(ctx, ctx.alice, ctx.agent, %{})

    assert {:ok, _} = remove(ctx, ctx.bob)

    assert %Run{status: :cancelled, failure_reason: :unauthorized} = reload(queued)
    assert %Run{status: :cancelled, failure_reason: :unauthorized} = reload(deferred)
    assert %Run{status: :cancelling, failure_reason: :unauthorized} = reload(running)
    assert %Run{status: :queued} = reload(alices)
    id = running.id
    assert_receive {:cancel_run, ^id}

    {:ok, report} = Report.Finished.new(%{run_id: id, status: :succeeded})
    assert Runs.finish(daemon_ctx(ctx.daemon), report) == :ok
    assert %Run{status: :cancelled, failure_reason: :unauthorized} = reload(running)
    refute_enqueued(worker: Retry)
  end

  test "leaving has the same effect", ctx do
    running = active(ctx, ctx.bob, ctx.agent, :running, ctx.daemon)
    queued = by(ctx, ctx.bob, ctx.agent, %{})

    assert {:ok, _} = Members.leave(ctx.bob_scope)
    assert %Run{status: :cancelling, failure_reason: :unauthorized} = reload(running)
    assert %Run{status: :cancelled, failure_reason: :unauthorized} = reload(queued)
  end

  test "demoting to viewer stops nothing", ctx do
    running = active(ctx, ctx.bob, ctx.agent, :running, ctx.daemon)
    queued = by(ctx, ctx.bob, ctx.agent, %{})

    assert {:ok, _} = Members.change_role(ctx.alice_scope, membership_id(ctx, ctx.bob), :viewer)
    assert reload(running).status == :running
    assert reload(queued).status == :queued
    refute_receive {:cancel_run, _}
  end

  test "the same user's runs in another workspace are not touched", ctx do
    other = workspace_fixture(ctx.alice)
    member_fixture(other, ctx.bob, :member)
    other_scope = workspace_scope_fixture(ctx.alice, other)
    managed_agent_fixture(other_scope, %{name: "other/dev", access: "workspace"})
    agent = agent_actor(other, "other/dev")
    elsewhere = active(ctx, ctx.bob, agent, :running, daemon_of(agent))
    elsewhere_queued = by(ctx, ctx.bob, agent, %{})

    assert {:ok, _} = remove(ctx, ctx.bob)
    assert reload(elsewhere).status == :running
    assert reload(elsewhere_queued).status == :queued
  end

  test "the source is also the agent's owner: unauthorized wins, once per run (scenario)",
       ctx do
    managed_agent_fixture(ctx.bob_scope, %{name: "bob/dev"})
    agent = agent_actor(ctx.workspace, "bob/dev")
    daemon = daemon_of(agent)
    Events.subscribe(Events.topic(:daemon, daemon.id))

    deferred = by(ctx, ctx.bob, agent, %{})
    Repo.update_all(from(r in Run, where: r.id == ^deferred.id), set: [status: :deferred])
    queued = by(ctx, ctx.bob, agent, %{})
    claimed = active(ctx, ctx.bob, agent, :claimed, daemon)
    running = active(ctx, ctx.bob, agent, :running, daemon)
    _ = updates()

    assert {:ok, _} = remove(ctx, ctx.bob)

    for run <- [deferred, queued, claimed, running] do
      assert reload(run).failure_reason == :unauthorized
    end

    assert reload(queued).status == :cancelled
    assert reload(deferred).status == :cancelled
    assert reload(claimed).status == :cancelling
    assert reload(running).status == :cancelling

    ids = Enum.map([deferred, queued, claimed, running], & &1.id)
    assert Enum.sort(updates()) == Enum.sort(ids)

    for id <- [claimed.id, running.id] do
      assert_receive {:cancel_run, ^id}
    end

    refute_receive {:cancel_run, _}

    # The daemon reports one; the other is ended by the sweep once the
    # daemon is offline. Both keep the reason.
    {:ok, report} = Report.Finished.new(%{run_id: running.id, status: :succeeded})
    assert Runs.finish(daemon_ctx(daemon), report) == :ok

    Repo.update_all(from(d in Daemon, where: d.id == ^daemon.id),
      set: [last_seen_at: DateTime.add(DateTime.utc_now(:second), -600, :second)]
    )

    assert :ok = perform_job(Sweep, %{})

    for run <- [claimed, running] do
      assert %Run{status: :cancelled, failure_reason: :unauthorized} = reload(run)
    end

    refute_enqueued(worker: Retry)
  end
end
