defmodule Helmsman.BQL.SquadFieldTest do
  use Helmsman.DataCase, async: true
  import Helmsman.SquadsFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{BQL, Squads, Tasks}

  setup do
    ctx = squads_fixture()

    assigned = fn name ->
      task_fixture(ctx.alice_scope, ctx.project.key, assignee: name, start: false)
    end

    Map.merge(ctx, %{
      team_task: assigned.("web-team"),
      lead_task: assigned.("keel/lead"),
      member_task: assigned.("keel/fe"),
      replacement_task: assigned.("keel/dev"),
      human_task: assigned.(ctx.squad.members |> List.last() |> Map.fetch!(:name)),
      unassigned_task: task_fixture(ctx.alice_scope, ctx.project.key)
    })
  end

  defp ids(scope, query) do
    assert {:ok, %{tasks: tasks}} = Tasks.query(scope, query)
    MapSet.new(tasks, & &1.id)
  end

  test "squad identity, current leader and human/agent members match without duplicates", ctx do
    expected =
      MapSet.new([
        ctx.team_task.ident,
        ctx.lead_task.ident,
        ctx.member_task.ident,
        ctx.human_task.ident
      ])

    for query <- ["squad = WEB-TEAM", "squad IN (missing, web-team)"] do
      assert ids(ctx.alice_scope, query) == expected
      assert {:ok, ast} = BQL.parse(query)
      assert ids(ctx.alice_scope, ast) == expected
      assert {:ok, %{total: 4}} = Tasks.query(ctx.alice_scope, query)
    end

    assert ids(ctx.alice_scope, "assignee_kind = squad") == MapSet.new([ctx.team_task.ident])
    assert ids(ctx.alice_scope, "squad = missing") == MapSet.new()

    negative = MapSet.new([ctx.replacement_task.ident, ctx.unassigned_task.ident])

    for query <- ["squad != web-team", "squad NOT IN (web-team)", "NOT squad = web-team"] do
      assert ids(ctx.alice_scope, query) == negative
      assert MapSet.disjoint?(expected, negative)
      assert MapSet.union(expected, negative) == ids(ctx.alice_scope, "")
    end
  end

  test "queries immediately reflect member removal and leader replacement", ctx do
    assert {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{members: []})

    assert ids(ctx.alice_scope, "squad = web-team") ==
             MapSet.new([ctx.team_task.ident, ctx.lead_task.ident])

    assert {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/dev"})

    assert ids(ctx.alice_scope, "squad = web-team") ==
             MapSet.new([ctx.team_task.ident, ctx.replacement_task.ident])

    refute MapSet.member?(ids(ctx.alice_scope, "squad = web-team"), ctx.lead_task.ident)
  end

  test "same squad name in another workspace cannot match or leak tasks", ctx do
    other = squads_fixture()
    task_fixture(other.alice_scope, other.project.key, assignee: "web-team", start: false)
    assert {:ok, %{total: 4}} = Tasks.query(ctx.alice_scope, "squad = web-team")
    assert {:ok, %{total: 1}} = Tasks.query(other.alice_scope, "squad = web-team")
  end
end
