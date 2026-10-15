defmodule Helmsman.Squads.OrchestrationScopeTest do
  # improve-squad-leader-orchestration 1.2: squad-orchestration 「编排根与编排
  # 范围」 (decisions 1, 2, 6).
  use Helmsman.DataCase, async: true
  use ExUnitProperties

  import Helmsman.OrchestrationFixtures
  import Helmsman.ProjectsFixtures

  alias Helmsman.{Repo, Tasks}
  alias Helmsman.Runs.TaskGrant
  alias Helmsman.Squads.Orchestration
  alias Helmsman.Tasks.Task

  setup do
    orchestration_fixture()
  end

  defp root(task, ctx), do: Orchestration.root(Repo.reload!(task), ctx.squad.id)

  defp scope(root, ctx),
    do: root |> Orchestration.scope_ids(ctx.squad.id) |> MapSet.to_list() |> Enum.sort()

  defp grant(task),
    do: Repo.one!(from(g in TaskGrant, where: g.task_id == ^task.id and g.kind == :requested))

  # A plain task of web-team with two subtasks the leader created outside
  # any epic.
  defp plain(ctx) do
    bos5 = task_fixture(ctx.alice_scope, ctx.project.key, %{title: "Plain"})
    {:ok, _} = Tasks.update(ctx.alice_scope, bos5.ident, %{assignee: "web-team", start: false})
    {scope, _run} = leader_run(ctx, ctx.lead, bos5)
    {:ok, bos6} = Tasks.create(scope, ctx.project.key, %{title: "Sub 6", start: false})
    {:ok, bos7} = Tasks.create(scope, ctx.project.key, %{title: "Sub 7", start: false})
    drop_queued()
    %{bos5: Repo.reload!(bos5), bos6: bos6, bos7: bos7}
  end

  test "a callback on a step: the root is the epic, the scope its steps", ctx do
    assert root(ctx.s1, ctx).id == ctx.epic.id
    assert scope(ctx.epic, ctx) == Enum.sort([ctx.s1.id, ctx.s2.id, ctx.s3.id])

    {_scope, run} = leader_run(ctx, ctx.lead, ctx.s1)
    assert "orchestrate" in run.capabilities
    assert run.capabilities == ["read", "write_task", "create_tasks", "delegate", "orchestrate"]
  end

  test "steps created under the epic record no root", ctx do
    assert grant(ctx.s1).root_task_id == nil
  end

  test "not across epics", ctx do
    other = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: :epic})
    {:ok, _} = Tasks.update(ctx.alice_scope, other.ident, %{assignee: "web-team", start: false})
    {scope, _} = leader_run(ctx, ctx.lead, other)

    {:ok, s21} =
      Tasks.create(scope, ctx.project.key, %{title: "Other", epic: other.ident, start: false})

    drop_queued()

    refute s21.id in scope(ctx.epic, ctx)

    assert {:error, {:orchestration, :outside, ident, root}} =
             Tasks.update(ctx.lead_scope, s21.ident, %{assignee: "keel/fe"})

    assert {ident, root} == {s21.ident, ctx.epic.ident}
    assert Repo.reload!(s21).assignee_id == nil
  end

  test "a plain task's subtasks", ctx do
    %{bos5: bos5, bos6: bos6, bos7: bos7} = plain(ctx)
    assert grant(bos6).root_task_id == bos5.id
    assert root(bos6, ctx).id == bos5.id
    assert scope(bos5, ctx) == Enum.sort([bos6.id, bos7.id])
  end

  test "a subtask attached to another epic leaves the scope for good", ctx do
    %{bos5: bos5, bos6: bos6, bos7: bos7} = plain(ctx)
    ops1 = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: :epic})

    {:ok, _} = Tasks.update(ctx.alice_scope, bos7.ident, %{epic: ops1.ident})
    assert grant(bos7).root_task_id == nil
    assert grant(bos7).squad_id == ctx.squad.id
    assert scope(bos5, ctx) == [bos6.id]

    {scope, _} = leader_run(ctx, ctx.lead, bos6)

    assert {:error, {:orchestration, :outside, _, _}} =
             Tasks.update(scope, bos7.ident, %{assignee: "keel/fe"})

    {:ok, _} = Tasks.update(ctx.alice_scope, bos7.ident, %{epic: ""})
    assert scope(bos5, ctx) == [bos6.id]
    assert root(bos7, ctx) == nil
  end

  test "a step the leader created, detached: outside; its callback has no root", ctx do
    {:ok, _} = Tasks.update(ctx.alice_scope, ctx.s2.ident, %{epic: ""})

    assert {:error, {:orchestration, :outside, _, _}} =
             Tasks.update(ctx.lead_scope, ctx.s2.ident, %{assignee: "keel/fe"})

    assert root(ctx.s2, ctx) == nil
    {_scope, run} = leader_run(ctx, ctx.lead, ctx.s2)
    refute "orchestrate" in run.capabilities
  end

  describe "the root rules, in order" do
    test "1. the task's assignee is the squad (before its epic)", ctx do
      # The epic is the squad's too; rule 1 wins.
      {:ok, _} =
        Tasks.update(ctx.alice_scope, ctx.s3.ident, %{assignee: "web-team", start: false})

      assert root(ctx.s3, ctx).id == ctx.s3.id
    end

    test "2. the task's epic's assignee is the squad", ctx do
      assert root(ctx.s2, ctx).id == ctx.epic.id
    end

    test "3. the root on the requested grant, while the squad owns it", ctx do
      %{bos5: bos5, bos6: bos6} = plain(ctx)
      assert root(bos6, ctx).id == bos5.id
      {:ok, _} = Tasks.update(ctx.alice_scope, bos5.ident, %{assignee: "keel/dev", start: false})
      assert root(bos6, ctx) == nil
    end

    test "4. none: no squad, or another workspace's squad id", ctx do
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      assert root(task, ctx) == nil
      assert Orchestration.root(Repo.reload!(ctx.s1), nil) == nil
    end
  end

  test "runs not as a squad and steps record no root", ctx do
    {scope, run} = leader_run(ctx, ctx.agent, ctx.epic, squad: false)
    refute "orchestrate" in run.capabilities

    {:ok, task} =
      Tasks.create(
        %{scope | run: %{scope.run | capabilities: ["read", "write_task", "create_tasks"]}},
        ctx.project.key,
        %{title: "x", start: false}
      )

    assert Repo.all(from(g in TaskGrant, where: g.task_id == ^task.id, select: g.root_task_id)) ==
             [nil]
  end

  property "a recorded root always sits on a task outside any epic", ctx do
    %{bos5: _bos5, bos6: bos6, bos7: bos7} = plain(ctx)
    ops1 = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: :epic})
    targets = ["", ctx.epic.ident, ops1.ident]

    check all(
            moves <- list_of({member_of([bos6, bos7]), member_of(targets)}, max_length: 8),
            max_runs: 20
          ) do
      for {task, epic} <- moves,
          do: {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{epic: epic})

      rooted =
        Repo.all(
          from(g in TaskGrant,
            join: t in Task,
            on: t.id == g.task_id,
            where: not is_nil(g.root_task_id),
            select: t.epic_id
          )
        )

      assert Enum.all?(rooted, &is_nil/1)
    end
  end
end
