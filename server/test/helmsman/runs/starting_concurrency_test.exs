defmodule Helmsman.Runs.StartingConcurrencyTest do
  # add-run-lifecycle 3.1a: the check before starting and the writes that
  # change what it reads are serialized on row locks (decision 24), in
  # either order and without deadlocks. Each side runs on a connection of
  # its own; writes join an outer transaction without retries, so a
  # deadlock surfaces as an error instead of being retried away.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{
    Agents,
    CommittedData,
    LockHarness,
    Members,
    Repo,
    Runs,
    Runtimes,
    Tasks,
    Workspaces
  }

  alias Helmsman.Runs.Run

  @moduletag timeout: 60_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture(%{access: "workspace"})
        {bob, bob_scope} = member_scope_fixture(ctx.workspace)
        task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
        Repo.delete_all(from(r in Run, where: r.task_id == ^task.id))
        daemon = daemon_of(ctx.agent)

        run =
          claimed_run(ctx.agent, daemon, task, [
            trigger("assign", ctx.workspace, bob, ctx.agent)
          ])

        Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, task: task, daemon: daemon, run: run})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id]) end)
    ctx
  end

  defp claimed_run(agent, daemon, task, triggers) do
    run_fixture(agent, %{
      task_id: task.id,
      status: :claimed,
      daemon_id: daemon.id,
      claimed_at: DateTime.utc_now(),
      triggers: triggers,
      root_initiator_user_id: hd(triggers)["initiator_user_id"]
    })
  end

  defp starting(ctx, run),
    do: fn -> Runs.starting(daemon_ctx(ctx.daemon), (run || ctx.run).id) end

  defp status(run) do
    CommittedData.unboxed(fn ->
      Repo.one!(from(r in Run, where: r.id == ^run.id, select: {r.status, r.failure_reason}))
    end)
  end

  # The write holds its locks (uncommitted) first; starting waits for it.
  defp write_first(ctx, write, run \\ nil) do
    {w, s} = LockHarness.interleave(write, :commit, starting(ctx, run))
    {s, w}
  end

  # Starting holds every lock but the run row's first; the write waits.
  defp starting_first(ctx, write, run \\ nil),
    do: LockHarness.interleave(starting(ctx, run), :starting_locked, write)

  defp membership(ctx, user),
    do: CommittedData.unboxed(fn -> Workspaces.get_membership(ctx.workspace.id, user.id) end)

  ## The five writes

  defp remove_bob(ctx) do
    id = membership(ctx, ctx.bob).id
    fn -> Members.remove(ctx.alice_scope, id) end
  end

  defp demote_bob(ctx) do
    id = membership(ctx, ctx.bob).id
    fn -> Members.change_role(ctx.alice_scope, id, :viewer) end
  end

  defp disable_agent(ctx), do: fn -> Agents.disable(ctx.alice_scope, "keel/dev") end

  defp disable_runtime(ctx) do
    id = CommittedData.unboxed(fn -> profile(ctx.agent).runtime_id end)
    fn -> Runtimes.disable(ctx.alice_scope, id) end
  end

  defp reassign(ctx) do
    alice = CommittedData.unboxed(fn -> human_actor(ctx.workspace, ctx.alice) end)
    fn -> Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: alice.name}) end
  end

  describe "removing the authorization source (scenario)" do
    test "removal first: starting waits, then aborts", ctx do
      assert {{:ok, {:abort, "cancelled"}}, {:ok, _}} = write_first(ctx, remove_bob(ctx))
      assert status(ctx.run) == {:cancelled, :unauthorized}
    end

    test "starting first: the removal waits, then stops the run", ctx do
      assert {{:ok, :proceed}, {:ok, _}} = starting_first(ctx, remove_bob(ctx))
      assert status(ctx.run) == {:cancelling, :unauthorized}
    end
  end

  describe "demoting the authorization source to viewer" do
    test "demotion first", ctx do
      assert {{:ok, {:abort, "unauthorized"}}, {:ok, _}} = write_first(ctx, demote_bob(ctx))
      assert status(ctx.run) == {:failed, :unauthorized}
    end

    test "starting first", ctx do
      assert {{:ok, :proceed}, {:ok, _}} = starting_first(ctx, demote_bob(ctx))
      assert status(ctx.run) == {:running, nil}
    end
  end

  describe "disabling the agent" do
    test "disabling first", ctx do
      assert {{:ok, {:abort, "cancelled"}}, {:ok, _}} = write_first(ctx, disable_agent(ctx))
      assert status(ctx.run) == {:cancelled, nil}
    end

    test "starting first", ctx do
      assert {{:ok, :proceed}, {:ok, _}} = starting_first(ctx, disable_agent(ctx))
      assert status(ctx.run) == {:cancelling, nil}
    end
  end

  describe "disabling the runtime" do
    test "disabling first", ctx do
      assert {{:ok, {:abort, "obsolete"}}, {:ok, _}} = write_first(ctx, disable_runtime(ctx))
      assert status(ctx.run) == {:failed, :obsolete}
    end

    test "starting first", ctx do
      assert {{:ok, :proceed}, {:ok, _}} = starting_first(ctx, disable_runtime(ctx))
      assert status(ctx.run) == {:running, nil}
    end
  end

  describe "changing the assignee" do
    test "the change first", ctx do
      assert {{:ok, {:abort, "obsolete"}}, {:ok, _}} = write_first(ctx, reassign(ctx))
      assert status(ctx.run) == {:failed, :obsolete}
    end

    test "starting first", ctx do
      assert {{:ok, :proceed}, {:ok, _}} = starting_first(ctx, reassign(ctx))
      assert status(ctx.run) == {:running, nil}
    end
  end

  describe "membership rows locked by ID, not by user ID" do
    # A: small user ID, joined late (large membership ID); B: the other way
    # round. The merged run's sources are A, then B.
    setup ctx do
      {a, b, run} =
        CommittedData.unboxed(fn ->
          a = user_fixture()
          b = user_fixture()
          member_fixture(ctx.workspace, b, :member)
          member_fixture(ctx.workspace, a, :member)
          Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [status: :succeeded])

          run =
            claimed_run(ctx.agent, ctx.daemon, ctx.task, [
              trigger("manual", ctx.workspace, a, ctx.agent),
              trigger("manual", ctx.workspace, b, ctx.agent)
            ])

          {a, b, run}
        end)

      # Runs first (on_exit is LIFO): with the workspace owner's data.
      on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, a.id, b.id]) end)
      assert a.id < b.id
      assert membership(ctx, a).id > membership(ctx, b).id
      %{a: a, b: b, merged: run}
    end

    test "removing A first, then starting", ctx do
      id = membership(ctx, ctx.a).id
      remove = fn -> Members.remove(ctx.alice_scope, id) end

      assert {{:ok, {:abort, "cancelled"}}, {:ok, _}} = write_first(ctx, remove, ctx.merged)
      assert status(ctx.merged) == {:cancelled, :unauthorized}
    end

    test "starting first, then removing A", ctx do
      id = membership(ctx, ctx.a).id
      remove = fn -> Members.remove(ctx.alice_scope, id) end

      assert {{:ok, :proceed}, {:ok, _}} = starting_first(ctx, remove, ctx.merged)
      assert status(ctx.merged) == {:cancelling, :unauthorized}
    end

    test "demoting A first: B's trigger remains", ctx do
      id = membership(ctx, ctx.a).id
      demote = fn -> Members.change_role(ctx.alice_scope, id, :viewer) end

      assert {{:ok, :proceed}, {:ok, _}} = write_first(ctx, demote, ctx.merged)
      run = CommittedData.unboxed(fn -> Repo.get!(Run, ctx.merged.id) end)
      assert run.status == :running
      assert run.root_initiator_user_id == ctx.b.id
      assert [%{"initiator_user_id" => b_id}] = run.triggers
      assert b_id == ctx.b.id
    end

    test "starting first, then demoting A", ctx do
      id = membership(ctx, ctx.a).id
      demote = fn -> Members.change_role(ctx.alice_scope, id, :viewer) end

      assert {{:ok, :proceed}, {:ok, _}} = starting_first(ctx, demote, ctx.merged)
      assert status(ctx.merged) == {:running, nil}
    end
  end
end
