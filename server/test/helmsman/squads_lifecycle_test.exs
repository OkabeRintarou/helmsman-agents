defmodule Helmsman.SquadsLifecycleTest do
  # add-squads 1.3: disabling, enabling, changing the leader and archiving
  # a member (squads spec "停用、启用与换 leader", decision 3).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Agents, Events, Squads}
  alias Helmsman.Runs.Run

  setup do
    ctx = squads_fixture()
    daemon = daemon_of(ctx.lead)
    Events.subscribe(Events.topic(:daemon, daemon.id))
    Map.put(ctx, :daemon, daemon)
  end

  defp task(ctx), do: task_fixture(ctx.alice_scope, ctx.project.key)
  defp reload(run), do: Repo.get!(Run, run.id)

  defp leader_run(ctx, agent, task, attrs \\ %{}) do
    run_fixture(
      agent,
      Map.merge(%{task_id: task.id, squad_id: ctx.squad.id}, attrs)
    )
  end

  defp running(ctx, agent, task, attrs \\ %{}) do
    leader_run(
      ctx,
      agent,
      task,
      Map.merge(
        %{status: :running, daemon_id: ctx.daemon.id, claimed_at: DateTime.utc_now()},
        attrs
      )
    )
  end

  test "disabling a squad cancels its queued leader runs and stops the running ones", ctx do
    queued = leader_run(ctx, ctx.lead, task(ctx))
    active = running(ctx, ctx.lead, task(ctx))
    # The leader's own runs, not as the squad, are left alone.
    own = run_fixture(ctx.lead, %{task_id: task(ctx).id})
    id = active.id

    assert {:ok, %{disabled: true}} = Squads.disable(ctx.alice_scope, "web-team")

    assert %Run{status: :cancelled, failure_reason: :obsolete} = reload(queued)
    assert %Run{status: :cancelling} = reload(active)
    assert_receive {:cancel_run, ^id}
    assert %Run{status: :queued} = reload(own)

    # Decision 15: a disabled squad cannot be assigned.
    bos3 = task(ctx)

    assert {:error, cs} =
             Helmsman.Tasks.update(ctx.alice_scope, bos3.ident, %{assignee: "web-team"})

    assert %{assignee: ["is disabled"]} = Agents.errors(cs)

    assert {:error, cs} =
             Helmsman.Tasks.create(ctx.alice_scope, ctx.project.key, %{
               title: "New",
               assignee: "web-team"
             })

    assert %{assignee: ["is disabled"]} = Agents.errors(cs)
    assert %{assignee_id: nil} = Repo.get!(Helmsman.Tasks.Task, bos3.id)
    assert runs_of(bos3.id) == []
    assert Repo.all(from(g in Helmsman.Runs.TaskGrant, where: g.task_id == ^bos3.id)) == []
  end

  test "enabling dispatches nothing again", ctx do
    queued = leader_run(ctx, ctx.lead, task(ctx))
    {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")
    count = Repo.aggregate(Run, :count)

    assert {:ok, %{disabled: false}} = Squads.enable(ctx.alice_scope, "web-team")
    assert Repo.aggregate(Run, :count) == count
    assert %Run{status: :cancelled} = reload(queued)
    refute_receive {:cancel_run, _}
  end

  test "changing the leader cancels the old leader's queued runs as the squad", ctx do
    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/lead2",
      runtime_id: ctx.runtime_id,
      access: "workspace"
    })

    bos4 = task(ctx)
    queued = leader_run(ctx, ctx.lead, bos4)
    active = running(ctx, ctx.lead, task(ctx))
    {_admin, admin_scope} = member_scope_fixture(ctx.workspace, :admin)

    assert {:ok, %{leader: %{name: "keel/lead2"}, cancelled_runs: cancelled}} =
             Squads.update(admin_scope, "web-team", %{leader: "keel/lead2"})

    assert cancelled == [bos4.ident]
    assert %Run{status: :cancelled, failure_reason: :obsolete} = reload(queued)
    # Runs in progress are not stopped.
    assert %Run{status: :running} = reload(active)
    refute_receive {:cancel_run, _}
  end

  test "a member cannot become the leader while it stays a member", ctx do
    assert {:error, cs} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/fe"})
    assert %{leader: [_]} = Agents.errors(cs)
    assert {:ok, %{leader: %{name: "keel/lead"}}} = Squads.get(ctx.alice_scope, "web-team")

    # With the list replaced in the same change it is checked as given.
    assert {:error, cs} =
             Squads.update(ctx.alice_scope, "web-team", %{
               leader: "keel/fe",
               members: [%{name: "keel/fe"}, %{name: "keel/review"}]
             })

    assert %{members: [_]} = Agents.errors(cs)

    assert {:ok, %{leader: %{name: "keel/fe"}, members: [%{name: "keel/review"}]}} =
             Squads.update(ctx.alice_scope, "web-team", %{
               leader: "keel/fe",
               members: [%{name: "keel/review"}]
             })
  end

  test "an unchanged leader cancels nothing", ctx do
    queued = leader_run(ctx, ctx.lead, task(ctx))

    assert {:ok, %{cancelled_runs: []}} =
             Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/lead", description: "x"})

    assert %Run{status: :queued} = reload(queued)
  end

  test "archiving a member removes it from the squad", ctx do
    {:ok, %{lock_version: v}} = Squads.get(ctx.alice_scope, "web-team")
    Events.subscribe(Squads.topic(ctx.workspace.id))
    squad_id = ctx.squad.id

    assert {:ok, _} = Agents.archive(ctx.alice_scope, "keel/qa")

    assert {:ok, %{members: members, lock_version: v2}} = Squads.get(ctx.alice_scope, "web-team")
    refute Enum.any?(members, &(&1.name == "keel/qa"))
    assert length(members) == 3
    assert v2 == v + 1
    assert_receive {:squad, ^squad_id}
  end

  test "archiving the leader keeps the squad and shows it", ctx do
    assert {:ok, _} = Agents.archive(ctx.alice_scope, "keel/lead")

    assert {:ok,
            %{leader: %{name: "keel/lead", archived: true, disabled: true}, members: [_, _, _, _]}} =
             Squads.get(ctx.alice_scope, "web-team")

    assert {:error, :agent_archived} =
             Squads.trigger_check(ctx.workspace.id, ctx.alice.id, ctx.squad.id)
  end
end

defmodule Helmsman.SquadsLifecycleConcurrencyTest do
  # add-squads 1.3: archiving a member while the squad is changed, each on
  # a connection of its own (lock order: identity rows, squad row, profile
  # rows). Both finish, without a deadlock, whichever goes first.
  use ExUnit.Case, async: false

  import Helmsman.SquadsFixtures

  alias Helmsman.{Agents, CommittedData, Squads, Tx}

  setup do
    ctx = CommittedData.unboxed(fn -> squads_fixture() end)

    on_exit(fn ->
      CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, ctx.carol.id])
    end)

    ctx
  end

  defp start(fun, hold?) do
    parent = self()

    fun = if hold?, do: held_open(fun, parent), else: fun

    Task.async(fn ->
      CommittedData.unboxed(fn ->
        send(parent, {:backend, self(), CommittedData.backend_pid()})
        fun.()
      end)
    end)
  end

  # `fun` in a transaction kept open until the test sends `:continue`.
  defp held_open(fun, parent), do: fn -> Tx.run(fn -> hold(fun.(), parent) end) end

  defp hold(result, parent) do
    send(parent, {:held, self()})

    receive do
      :continue -> result
    end
  end

  defp race(first, second) do
    first = start(first, true)
    %Task{pid: pid} = first
    assert_receive {:backend, ^pid, _}, 5_000
    assert_receive {:held, ^pid}, 5_000

    second = start(second, false)
    %Task{pid: pid2} = second
    assert_receive {:backend, ^pid2, backend}, 5_000
    CommittedData.await_lock_wait(backend)
    send(first.pid, :continue)
    {Task.await(first, 5_000), Task.await(second, 5_000)}
  end

  defp archive(ctx), do: fn -> Agents.archive(ctx.alice_scope, "keel/qa") end

  defp change(ctx),
    do: fn ->
      Squads.update(ctx.alice_scope, "web-team", %{
        members: [%{name: "keel/qa"}, %{name: "keel/fe"}]
      })
    end

  defp members(ctx) do
    CommittedData.unboxed(fn ->
      {:ok, squad} = Squads.get(ctx.alice_scope, "web-team")
      Enum.map(squad.members, & &1.name)
    end)
  end

  test "archive first, then the change sees the member archived", ctx do
    assert {{:ok, _}, {:error, %Ecto.Changeset{}}} = race(archive(ctx), change(ctx))
    refute "keel/qa" in members(ctx)
  end

  test "change first, then archive removes the member", ctx do
    assert {{:ok, _}, {:ok, _}} = race(change(ctx), archive(ctx))
    assert members(ctx) == ["keel/fe"]
  end
end
