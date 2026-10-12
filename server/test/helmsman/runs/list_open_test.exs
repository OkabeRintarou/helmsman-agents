defmodule Helmsman.Runs.ListOpenTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{QueryCount, Runs}

  setup do
    ctx = dispatch_fixture()
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    Map.merge(ctx, %{viewer_scope: viewer_scope, at: DateTime.utc_now()})
  end

  defp ids(summaries), do: Enum.map(summaries, & &1.id)
  defp cursor(summary), do: {summary.priority, summary.inserted_at, summary.id}

  defp pending(agent, at, seconds, attrs \\ %{}),
    do: run_fixture(agent, Map.merge(%{inserted_at: DateTime.add(at, seconds)}, attrs))

  test "active and pending apart, pending paged in claim order", ctx do
    at = ctx.at

    active =
      for n <- 1..2,
          do: run_fixture(ctx.agent, %{status: :running, claimed_at: DateTime.add(at, -n)}).id

    p3 = pending(ctx.agent, at, 3, %{priority: 3})
    p2_old = pending(ctx.agent, at, 1, %{priority: 2})
    p2_new = pending(ctx.agent, at, 2, %{priority: 2, status: :deferred})
    for _ <- 1..100, do: run_fixture(ctx.agent, %{status: :succeeded})

    assert {:ok, %{active: act, pending: page, pending_total: 3}} =
             Runs.list_open(ctx.viewer_scope, {:agent, "keel/dev"}, pending_limit: 2)

    assert ids(act) == Enum.reverse(active)
    assert ids(page) == [p3.id, p2_old.id]
    assert Enum.all?(page, &is_map_key(&1, :triggers))

    assert {:ok, %{active: ^act, pending: [last], pending_total: 3}} =
             Runs.list_open(ctx.viewer_scope, {:agent, "keel/dev"},
               pending_limit: 2,
               pending_after: cursor(List.last(page))
             )

    assert last.id == p2_new.id
  end

  test "a raised priority shows in its place when read again from the first page", ctx do
    [a, b, c, d] = for n <- 1..4, do: pending(ctx.agent, ctx.at, n)
    target = {:agent, "keel/dev"}

    {:ok, %{pending: first}} = Runs.list_open(ctx.viewer_scope, target, pending_limit: 2)
    assert ids(first) == [a.id, b.id]

    # A merged trigger raises the priority of a run of the second page.
    Repo.update!(Ecto.Changeset.change(d, priority: 3))

    reread = read_pending(ctx.viewer_scope, target, 4)
    assert ids(reread) == [d.id, a.id, b.id, c.id]
    assert reread |> ids() |> Enum.uniq() |> length() == 4
  end

  defp read_pending(scope, target, wanted, after_key \\ nil, acc \\ []) do
    {:ok, %{pending: page}} =
      Runs.list_open(scope, target, pending_limit: 2, pending_after: after_key)

    acc = acc ++ page

    if page == [] or length(acc) >= wanted,
      do: acc,
      else: read_pending(scope, target, wanted, cursor(List.last(page)), acc)
  end

  test "a task's pending runs are complete and ignore paging", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    runtime_id = profile(ctx.agent).runtime_id

    agents =
      for n <- 1..26 do
        managed_agent_fixture(ctx.alice_scope, %{name: "bulk/#{n}", runtime_id: runtime_id})
        agent_actor(ctx.workspace, "bulk/#{n}")
      end

    slots =
      for {agent, n} <- Enum.with_index(agents), lane <- [:work, :reply], do: {agent, n, lane}

    runs =
      for {agent, n, lane} <- Enum.take(slots, 51),
          do: pending(agent, ctx.at, n, %{task_id: task.id, lane: lane})

    running =
      run_fixture(ctx.agent, %{task_id: task.id, status: :running, claimed_at: ctx.at})

    assert {:ok, %{active: [active], pending: pending, pending_total: 51}} =
             Runs.list_open(ctx.viewer_scope, {:task, task.ident},
               pending_limit: 2,
               pending_after: {0, ctx.at, 0}
             )

    assert active.id == running.id
    assert length(pending) == 51

    expected =
      runs
      |> Enum.sort_by(&{-&1.priority, DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
      |> Enum.map(& &1.id)

    assert ids(pending) == expected

    # Out-of-range paging options are ignored for a task.
    assert {:ok, %{pending_total: 51}} =
             Runs.list_open(ctx.viewer_scope, {:task, task.ident}, pending_limit: 0)
  end

  test "deferred and queued count together; same priority is oldest first", ctx do
    old = pending(ctx.agent, ctx.at, 1, %{status: :deferred})
    new = pending(ctx.agent, ctx.at, 2)
    run_fixture(ctx.agent, %{status: :cancelled})

    assert {:ok, %{active: [], pending: pending, pending_total: 2}} =
             Runs.list_open(ctx.viewer_scope, {:agent, "keel/dev"})

    assert ids(pending) == [old.id, new.id]
  end

  test "the number of queries does not depend on the number of runs", ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/busy"})
    busy = agent_actor(ctx.workspace, "keel/busy")

    seed = fn agent, n ->
      for i <- 1..n do
        run_fixture(agent, %{status: :running, claimed_at: DateTime.add(ctx.at, i)})
        pending(agent, ctx.at, i)
        run_fixture(agent, %{status: :succeeded})
      end
    end

    seed.(ctx.agent, 1)
    seed.(busy, 50)

    {{:ok, small}, few} =
      QueryCount.count(fn -> Runs.list_open(ctx.viewer_scope, {:agent, "keel/dev"}) end)

    {{:ok, large}, more} =
      QueryCount.count(fn -> Runs.list_open(ctx.viewer_scope, {:agent, "keel/busy"}) end)

    assert few == more
    assert {length(small.active), length(small.pending), small.pending_total} == {1, 1, 1}
    assert {length(large.active), length(large.pending), large.pending_total} == {50, 50, 50}
    assert Enum.all?(large.active ++ large.pending, &(&1.agent == "keel/busy"))
  end

  test "unknown targets, bad options and missing permission", ctx do
    Repo.insert!(
      Actor.create_changeset(
        %Actor{workspace_id: ctx.workspace.id, owner_id: ctx.alice.id, kind: :agent},
        %{name: "outside/bot"}
      )
    )

    other = dispatch_fixture()
    other_task = task_fixture(other.alice_scope, other.project.key, %{title: "elsewhere"})
    scope = ctx.viewer_scope

    for target <- [
          {:agent, "nope"},
          {:agent, "outside/bot"},
          {:task, "NOPE-1"},
          {:task, "not an ident"}
        ] do
      assert {:error, :not_found} = Runs.list_open(scope, target)
    end

    # This workspace has no task: another workspace's ident is not found.
    assert {:error, :not_found} = Runs.list_open(scope, {:task, other_task.ident})

    for opts <- [
          [pending_limit: 0],
          [pending_limit: 201],
          [pending_limit: "2"],
          [pending_after: {1, 2}],
          [pending_after: {1, "2026-01-01", 3}],
          %{pending_limit: 2},
          [:bad]
        ] do
      assert {:error, :invalid_opts} = Runs.list_open(scope, {:agent, "keel/dev"}, opts)
    end

    assert {:ok, _} = Runs.list_open(scope, {:agent, "keel/dev"}, pending_limit: 200)

    assert {:error, :forbidden} =
             Runs.list_open(%{scope | role: nil}, {:agent, "keel/dev"})
  end

  test "an archived agent's open runs are listed", ctx do
    run = run_fixture(ctx.agent, %{status: :running})
    {:ok, _} = Helmsman.Agents.archive(ctx.alice_scope, "keel/dev")

    assert {:ok, %{active: [%{id: id}]}} =
             Runs.list_open(ctx.viewer_scope, {:agent, "keel/dev"})

    assert id == run.id
  end
end
