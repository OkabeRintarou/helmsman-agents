defmodule Helmsman.Runs.ClaimTest do
  # add-run-lifecycle 2.2: claiming (decisions 3, 24), in the sandbox.
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.{Daemon, DaemonWorkspace, Runtime}
  alias Helmsman.{Events, Runs, Tasks}
  alias Helmsman.Runs.{Run, RunToken}
  alias Helmsman.Workspaces.Membership
  alias HelmsmanProtocol.RunSpec

  @base_url "http://localhost:4000"

  setup do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)
    Map.merge(ctx, %{daemon: daemon, profile: profile(ctx.agent)})
  end

  defp claim(ctx), do: Runs.claim(daemon_ctx(ctx.daemon), @base_url)
  defp reload(run), do: Repo.get!(Run, run.id)
  defp ids({:ok, specs}), do: specs |> Enum.map(& &1.run_id) |> Enum.sort()

  defp set_profile(ctx, changes),
    do: Repo.update_all(from(p in AgentProfile, where: p.id == ^ctx.profile.id), set: changes)

  test "a claimed run gets the daemon, a token, its capabilities and a description", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run = run_fixture(ctx.agent, %{task_id: task.id, capabilities: ["read"]})
    Events.subscribe(Events.topic(:run, run.id))

    assert {:ok, [%RunSpec{run_id: id, mcp: %{url: url, token: "hmr_" <> _}}]} = claim(ctx)
    assert id == run.id
    assert url == @base_url <> "/mcp"

    claimed = reload(run)
    assert %Run{status: :claimed, daemon_id: daemon_id, claimed_at: %DateTime{}} = claimed
    assert daemon_id == ctx.daemon.id
    assert claimed.capabilities == ["read", "write_task"]
    assert Repo.get_by(RunToken, run_id: run.id)
    assert_receive {:run_updated, %{id: ^id, status: "claimed", daemon: "test-machine"}}
  end

  test "free slots: the daemon's limit minus its active runs (scenario)", ctx do
    Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), set: [max_concurrency: 2])
    set_profile(ctx, max_concurrency: 10)
    run_fixture(ctx.agent, %{status: :running, daemon_id: ctx.daemon.id})
    queued = for _ <- 1..3, do: run_fixture(ctx.agent)

    assert [id] = ids(claim(ctx))
    assert id == hd(queued).id
    assert Enum.count(queued, &(reload(&1).status == :queued)) == 2
    assert claim(ctx) == {:ok, []}
  end

  test "the agent's concurrency limit (scenario)", ctx do
    set_profile(ctx, max_concurrency: 1)
    [one, two] = for _ <- 1..2, do: task_fixture(ctx.alice_scope, ctx.project.key)
    run_fixture(ctx.agent, %{task_id: one.id, status: :running, daemon_id: ctx.daemon.id})
    queued = run_fixture(ctx.agent, %{task_id: two.id})

    assert claim(ctx) == {:ok, []}
    assert reload(queued).status == :queued
  end

  test "a task has at most one active run", ctx do
    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/other",
      runtime_id: ctx.profile.runtime_id
    })

    other = agent_actor(ctx.workspace, "keel/other")
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    first = run_fixture(ctx.agent, %{task_id: task.id, priority: 3})
    second = run_fixture(other, %{task_id: task.id})

    assert ids(claim(ctx)) == [first.id]
    assert reload(second).status == :queued
  end

  test "highest priority first, then the oldest", ctx do
    Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), set: [max_concurrency: 1])
    _low = run_fixture(ctx.agent, %{priority: 1})
    high = run_fixture(ctx.agent, %{priority: 3})
    assert ids(claim(ctx)) == [high.id]
  end

  test "an assigned run whose assignee changed while queued is cancelled (scenario)", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
    [run] = runs_of(task.id)
    alice = human_actor(ctx.workspace, ctx.alice)
    assert {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: alice.name})

    assert claim(ctx) == {:ok, []}
    assert %Run{status: :cancelled, failure_reason: :obsolete} = reload(run)
    refute Repo.get_by(RunToken, run_id: run.id)
  end

  test "a merged run whose earliest source left is claimed for the others (scenario)", ctx do
    {bob, _bob_scope} = member_scope_fixture(ctx.workspace)
    set_profile(ctx, access: "workspace")

    run =
      run_fixture(ctx.agent, %{
        triggers: [
          trigger("assign", ctx.workspace, bob, ctx.agent),
          trigger("manual", ctx.workspace, ctx.alice, ctx.agent)
        ],
        root_initiator_user_id: bob.id
      })

    Repo.delete_all(
      from(m in Membership, where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^bob.id)
    )

    assert ids(claim(ctx)) == [run.id]
    claimed = reload(run)
    assert claimed.root_initiator_user_id == ctx.alice.id
    assert [%{"initiator_user_id" => alice_id}] = claimed.triggers
    assert alice_id == ctx.alice.id
  end

  test "a source whose membership row is gone is unauthorized", ctx do
    {bob, _bob_scope} = member_scope_fixture(ctx.workspace)
    set_profile(ctx, access: "workspace")

    run =
      run_fixture(ctx.agent, %{
        triggers: [trigger("manual", ctx.workspace, bob, ctx.agent)],
        root_initiator_user_id: bob.id
      })

    Repo.delete_all(
      from(m in Membership, where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^bob.id)
    )

    assert claim(ctx) == {:ok, []}
    assert %Run{status: :cancelled, failure_reason: :unauthorized} = reload(run)
  end

  test "a run that is not due is not claimed", ctx do
    run = run_fixture(ctx.agent, %{not_before: DateTime.add(DateTime.utc_now(), 60, :second)})
    assert claim(ctx) == {:ok, []}
    assert reload(run).status == :queued
  end

  test "not from a disabled runtime, an unserved workspace or one where the user is a viewer",
       ctx do
    run = run_fixture(ctx.agent)

    for {undo, change} <- [
          {fn -> set_runtime(ctx, disabled_at: nil) end,
           fn -> set_runtime(ctx, disabled_at: DateTime.utc_now(:second)) end},
          {fn -> serve(ctx) end, fn -> Repo.delete_all(served(ctx)) end},
          {fn -> set_role(ctx, :owner) end, fn -> set_role(ctx, :viewer) end}
        ] do
      change.()
      assert claim(ctx) == {:ok, []}
      assert reload(run).status == :queued
      undo.()
    end

    assert ids(claim(ctx)) == [run.id]
  end

  test "another authorization epoch or a revoked daemon is reauthorized", ctx do
    run = run_fixture(ctx.agent)
    stale = %{daemon_ctx(ctx.daemon) | auth_epoch: ctx.daemon.auth_epoch + 1}
    assert Runs.claim(stale, @base_url) == {:error, :reauthorized}

    Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id),
      set: [revoked_at: DateTime.utc_now(:second)]
    )

    assert claim(ctx) == {:error, :reauthorized}
    assert reload(run).status == :queued
  end

  test "the scan stops after 200 candidates", ctx do
    set_profile(ctx, max_concurrency: 1)
    run_fixture(ctx.agent, %{status: :running, daemon_id: ctx.daemon.id})
    Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), set: [max_concurrency: 4])
    for _ <- 1..210, do: run_fixture(ctx.agent)
    assert claim(ctx) == {:ok, []}
  end

  defp set_runtime(ctx, changes),
    do: Repo.update_all(from(r in Runtime, where: r.id == ^ctx.profile.runtime_id), set: changes)

  defp served(ctx),
    do:
      from(w in DaemonWorkspace,
        where: w.daemon_id == ^ctx.daemon.id and w.workspace_id == ^ctx.workspace.id
      )

  defp serve(ctx),
    do:
      Repo.insert!(%DaemonWorkspace{
        daemon_id: ctx.daemon.id,
        workspace_id: ctx.workspace.id,
        inserted_at: DateTime.utc_now(:second)
      })

  defp set_role(ctx, role),
    do:
      Repo.update_all(
        from(m in Membership,
          where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.alice.id
        ),
        set: [role: role]
      )
end

defmodule Helmsman.Runs.ClaimLockTest do
  # add-run-lifecycle 2.2: claiming never waits for a writer (decision 24).
  # Each writer holds its locks on a connection of its own, uncommitted.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{
    Agents,
    CommittedData,
    Locks,
    Members,
    Repo,
    Runs,
    Runtimes,
    Tasks,
    Tx,
    Workspaces
  }

  alias Helmsman.Runs.Run

  @base_url "http://localhost:4000"
  @fast_us 1_000_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture(%{access: "workspace"})
        {bob, bob_scope} = member_scope_fixture(ctx.workspace)
        task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})

        Map.merge(ctx, %{
          bob: bob,
          bob_scope: bob_scope,
          task: task,
          daemon: daemon_of(ctx.agent),
          run: hd(runs_of(task.id))
        })
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id]) end)
    ctx
  end

  # Runs `fun` in a transaction on its own connection and holds it open
  # until `release/1`.
  defp hold(fun) do
    parent = self()

    task = Task.async(fn -> held_unboxed(fun, parent) end)

    assert_receive {:held, pid, _result}, 5_000
    {task, pid}
  end

  defp held_unboxed(fun, parent),
    do: CommittedData.unboxed(fn -> Tx.run(fn -> held(fun, parent) end) end)

  defp held(fun, parent) do
    result = fun.()
    send(parent, {:held, self(), result})

    receive do
      :release -> result
    end
  end

  defp release({task, pid}) do
    send(pid, :release)
    Task.await(task)
  end

  defp claim(ctx) do
    CommittedData.unboxed(fn ->
      {us, result} = :timer.tc(fn -> Runs.claim(daemon_ctx(ctx.daemon), @base_url) end)
      assert us < @fast_us, "claim waited #{us} µs"
      result
    end)
  end

  defp status(run),
    do:
      CommittedData.unboxed(fn ->
        Repo.one!(from(r in Run, where: r.id == ^run.id, select: {r.status, r.failure_reason}))
      end)

  defp lock_row(query), do: fn -> {:ok, Repo.one!(lock(query, "FOR UPDATE"))} end

  test "an import (exclusive maintenance lock) makes the workspace skipped", ctx do
    held = hold(fn -> {:ok, Locks.maint_exclusive!(ctx.workspace.id)} end)
    assert claim(ctx) == {:ok, []}
    assert status(ctx.run) == {:queued, nil}
    release(held)
    assert {:ok, [_spec]} = claim(ctx)
  end

  test "an agent being disabled: claim returns at once, the run stays queued (scenario)", ctx do
    held = hold(fn -> Agents.disable(ctx.alice_scope, "keel/dev") end)
    assert claim(ctx) == {:ok, []}
    assert status(ctx.run) == {:queued, nil}
    release(held)
    assert status(ctx.run) == {:cancelled, :obsolete}
    assert claim(ctx) == {:ok, []}
  end

  test "an actor row held FOR UPDATE", ctx do
    held = hold(lock_row(from(a in Helmsman.Actors.Actor, where: a.id == ^ctx.agent.id)))
    assert claim(ctx) == {:ok, []}
    assert status(ctx.run) == {:queued, nil}
    release(held)
    assert {:ok, [_spec]} = claim(ctx)
  end

  test "a membership row held by a role change, then the new role applies", ctx do
    run =
      CommittedData.unboxed(fn ->
        run_fixture(ctx.agent, %{
          triggers: [trigger("manual", ctx.workspace, ctx.bob, ctx.agent)],
          root_initiator_user_id: ctx.bob.id
        })
      end)

    CommittedData.unboxed(fn -> Repo.delete_all(from(r in Run, where: r.id == ^ctx.run.id)) end)

    membership =
      CommittedData.unboxed(fn -> Workspaces.get_membership(ctx.workspace.id, ctx.bob.id) end)

    held = hold(fn -> Members.change_role(ctx.alice_scope, membership.id, :viewer) end)
    assert claim(ctx) == {:ok, []}
    assert status(run) == {:queued, nil}
    release(held)
    assert claim(ctx) == {:ok, []}
    assert status(run) == {:cancelled, :unauthorized}
  end

  test "a task row held by an update, then the new assignee applies", ctx do
    alice = CommittedData.unboxed(fn -> human_actor(ctx.workspace, ctx.alice) end)
    held = hold(fn -> Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: alice.name}) end)
    assert claim(ctx) == {:ok, []}
    assert status(ctx.run) == {:queued, nil}
    release(held)
    assert claim(ctx) == {:ok, []}
    assert status(ctx.run) == {:cancelled, :obsolete}
  end

  test "a runtime row held by disabling it", ctx do
    runtime_id = CommittedData.unboxed(fn -> profile(ctx.agent).runtime_id end)
    held = hold(fn -> Runtimes.disable(ctx.alice_scope, runtime_id) end)
    assert claim(ctx) == {:ok, []}
    assert status(ctx.run) == {:queued, nil}
    release(held)
    assert status(ctx.run) == {:cancelled, :obsolete}
  end
end
