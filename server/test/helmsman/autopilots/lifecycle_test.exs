defmodule Helmsman.Autopilots.LifecycleTest do
  # add-autopilots 1.4: disabling, enabling, deleting (decision 10).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentsFixtures
  import Helmsman.AutopilotsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Autopilots, Members, Workspaces}
  alias Helmsman.Autopilots.Workers.Fire
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  setup do
    ctx = autopilots_fixture()

    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/triage",
      runtime_id: profile(ctx.agent).runtime_id,
      access: "owner_only"
    })

    ctx
  end

  test "disabling with a queued request: it is cancelled, the started one goes on", ctx do
    view = autopilot_fixture(ctx.alice_scope, %{overlap: "queue"})
    {:ok, started} = Autopilots.run_now(ctx.alice_scope, view.id)
    {:ok, pending} = Autopilots.run_now(ctx.alice_scope, view.id)
    assert {started.status, pending.status} == {:started, :pending}

    {:ok, disabled} = Autopilots.disable(ctx.alice_scope, view.id)
    refute disabled.enabled
    assert disabled.disabled_reason == :manual
    assert disabled.next_run_at == nil

    [s, p] = records_of(view)
    assert {s.status, p.status, p.reason} == {:started, :cancelled, "autopilot_disabled"}
    assert Repo.get!(Run, s.run_id).status == :queued
  end

  test "an admin disables alice's autopilot on her owner_only agent", ctx do
    view = autopilot_fixture(ctx.alice_scope, %{agent: "keel/triage"})

    assert {:ok, %{enabled: false, disabled_reason: :manual}} =
             Autopilots.disable(ctx.carol_scope, view.id)

    # A member who may not trigger it may not.
    assert Autopilots.disable(ctx.bob_scope, view.id) == {:error, :forbidden}
    # The source does not change.
    assert autopilot_row(view).initiator_user_id == ctx.alice.id
  end

  test "disabling keeps bob as the source", ctx do
    view = autopilot_fixture(ctx.bob_scope)
    {:ok, _} = Autopilots.disable(ctx.carol_scope, view.id)
    assert autopilot_row(view).initiator_user_id == ctx.bob.id
  end

  test "the source leaving disables their autopilots in the same transaction", ctx do
    a = autopilot_fixture(ctx.bob_scope)
    b = autopilot_fixture(ctx.bob_scope)
    c = autopilot_fixture(ctx.alice_scope)

    membership = Workspaces.get_membership(ctx.workspace.id, ctx.bob.id)
    {:ok, _} = Members.remove(ctx.alice_scope, membership.id)

    for v <- [a, b],
        do: assert(%{enabled: false, disabled_reason: :initiator_left} = autopilot_row(v))

    assert autopilot_row(c).enabled
  end

  test "enabling resets the failure count and plans the next time", ctx do
    view = autopilot_fixture(ctx.alice_scope, %{cron: "0 9 * * *"})
    {:ok, _} = Autopilots.disable(ctx.alice_scope, view.id)

    Repo.update_all(from(a in Autopilots.Autopilot, where: a.id == ^view.id),
      set: [consecutive_failures: 5, disabled_reason: :consecutive_failures]
    )

    at(~U[2026-10-20 10:00:00Z])
    {:ok, enabled} = Autopilots.enable(ctx.bob_scope, view.id)
    assert enabled.enabled and enabled.disabled_reason == nil
    assert enabled.consecutive_failures == 0
    assert enabled.next_run_at == ~U[2026-10-21 09:00:00.000000Z]
    assert autopilot_row(view).initiator_user_id == ctx.bob.id

    assert_enqueued(
      worker: Fire,
      args: %{autopilot_id: view.id, at: "2026-10-21T09:00:00.000000Z"}
    )
  end

  test "deleting keeps the task it created", ctx do
    view = autopilot_fixture(ctx.alice_scope)
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    assert record.task_id

    assert {:ok, _} = Autopilots.delete(ctx.alice_scope, view.id)
    assert records_of(view) == []
    assert Repo.get(Autopilots.Autopilot, view.id) == nil
    assert %Task{} = Repo.get(Task, record.task_id)
    assert Repo.get!(Run, record.run_id).status == :queued
  end

  test "deleting a run-only autopilot cancels its queued run, not a running one", ctx do
    queued = autopilot_fixture(ctx.alice_scope, %{mode: "run_only", project: nil})
    running = autopilot_fixture(ctx.alice_scope, %{mode: "run_only", project: nil})
    {:ok, q} = Autopilots.run_now(ctx.alice_scope, queued.id)
    {:ok, r} = Autopilots.run_now(ctx.alice_scope, running.id)
    Repo.update_all(from(x in Run, where: x.id == ^r.run_id), set: [status: :running])

    {:ok, _} = Autopilots.delete(ctx.alice_scope, queued.id)
    {:ok, _} = Autopilots.delete(ctx.alice_scope, running.id)

    assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, q.run_id)
    assert %Run{status: :running} = Repo.get!(Run, r.run_id)
  end
end

defmodule Helmsman.Autopilots.LifecycleConcurrencyTest do
  # add-autopilots 1.4: removing a member and saving an autopilot whose
  # source they are, on two connections, in both orders: no deadlock.
  use ExUnit.Case, async: false

  import Helmsman.AutopilotsFixtures

  alias Helmsman.{Autopilots, CommittedData, LockHarness, Members, Repo, Workspaces}
  alias Helmsman.Autopilots.Autopilot

  @moduletag timeout: 60_000

  setup do
    ctx = CommittedData.unboxed(fn -> autopilots_fixture() end)
    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, ctx.carol.id]) end)

    view = CommittedData.unboxed(fn -> autopilot_fixture(ctx.bob_scope) end)

    membership =
      CommittedData.unboxed(fn -> Workspaces.get_membership(ctx.workspace.id, ctx.bob.id) end)

    Map.merge(ctx, %{view: view, membership: membership})
  end

  defp remove(ctx), do: fn -> Members.remove(ctx.alice_scope, ctx.membership.id) end

  defp save(ctx),
    do: fn -> Autopilots.update(ctx.alice_scope, ctx.view.id, %{instructions: "Mine now"}) end

  defp row(ctx), do: CommittedData.unboxed(fn -> Repo.get!(Autopilot, ctx.view.id) end)

  test "the removal first: the save waits, then keeps alice as the source", ctx do
    {removed, saved} = LockHarness.interleave(remove(ctx), :commit, save(ctx))
    assert {:ok, _} = removed
    assert {:ok, _} = saved
    row = row(ctx)
    assert row.initiator_user_id == ctx.alice.id
    # It was disabled by the removal (bob was its source then).
    assert {row.enabled, row.disabled_reason} == {false, :initiator_left}
  end

  test "the save first: the removal waits and leaves alice's autopilot enabled", ctx do
    {saved, removed} = LockHarness.interleave(save(ctx), :commit, remove(ctx))
    assert {:ok, _} = saved
    assert {:ok, _} = removed
    row = row(ctx)
    assert {row.initiator_user_id, row.enabled} == {ctx.alice.id, true}
  end
end
