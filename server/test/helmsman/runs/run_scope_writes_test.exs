defmodule Helmsman.Runs.RunScopeWritesTest do
  # A run token writes only its own task (decision 11) and every record it
  # writes names the run (decision 12).
  use Helmsman.DataCase, async: true

  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Feedback, Tasks}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Tasks.{Task, TaskEvent}

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    other = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.merge(ctx, %{task: task, other: other})
  end

  defp run_scope(ctx, caps, task \\ :task) do
    task_id = if task, do: ctx[task].id

    run =
      run_fixture(ctx.agent, %{task_id: task_id, status: :running, capabilities: caps})

    {scope, _token} = run_scope_fixture(run)
    scope
  end

  defp snapshot(task) do
    task = Repo.get!(Task, task.id)

    {task.lock_version, task.status, task.assignee_id, task.feedback_seq,
     Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^task.id), :count)}
  end

  describe "another task" do
    setup ctx do
      {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.other.ident, %{content: "mine"})
      Events.subscribe(Events.topic(:task, ctx.other.id))
      %{scope: run_scope(ctx, ["read", "write_task"]), entry: entry}
    end

    test "update, transition, add and revise feedback are forbidden, nothing written", ctx do
      before = snapshot(ctx.other)
      id = Feedback.Id.build(ctx.other.ident, ctx.entry.seq)

      assert {:error, :forbidden} = Tasks.update(ctx.scope, ctx.other.ident, %{title: "X"})
      assert {:error, :forbidden} = Tasks.transition(ctx.scope, ctx.other.ident, :in_progress)
      assert {:error, :forbidden} = Feedback.add(ctx.scope, ctx.other.ident, %{content: "x"})
      assert {:error, :forbidden} = Feedback.revise(ctx.scope, id, %{content: "x"})

      assert snapshot(ctx.other) == before
      refute_receive {:feedback_added, _}
      refute_receive {:task_updated, _}
      refute_receive {:task_transitioned, _}
    end

    test "reading is fine", ctx do
      assert {:ok, _} = Tasks.get(ctx.scope, ctx.other.ident)
      assert {:ok, _} = Feedback.list(ctx.scope, ctx.other.ident)
    end
  end

  test "own task: writes allowed; without write_task: forbidden", ctx do
    scope = run_scope(ctx, ["read", "write_task"])
    assert {:ok, _} = Tasks.update(scope, ctx.task.ident, %{title: "Mine"})
    assert {:ok, _} = Feedback.add(scope, ctx.task.ident, %{content: "x"})

    read_only = run_scope(ctx, ["read"], :other)
    assert {:error, :forbidden} = Tasks.update(read_only, ctx.other.ident, %{title: "No"})
  end

  test "create_tasks: a new task by the agent, which the run then cannot edit", ctx do
    without = run_scope(ctx, ["read", "write_task"])
    assert {:error, :forbidden} = Tasks.create(without, ctx.project.key, %{title: "New"})

    scope = run_scope(ctx, ["read", "write_task", "create_tasks"])
    assert {:ok, new} = Tasks.create(scope, ctx.project.key, %{title: "New"})
    assert new.created_by.name == "keel/dev"

    assert [%TaskEvent{source_run_id: run_id}] =
             Repo.all(from(e in TaskEvent, where: e.task_id == ^new.id))

    assert run_id == scope.run.id
    assert {:error, :forbidden} = Tasks.update(scope, new.ident, %{title: "Edited"})
  end

  test "records of a run carry its ID; others do not", ctx do
    scope = run_scope(ctx, ["read", "write_task"])
    run_id = scope.run.id

    {:ok, entry} = Feedback.add(scope, ctx.task.ident, %{content: "from the run"})

    {:ok, revised} =
      Feedback.revise(scope, Feedback.Id.build(ctx.task.ident, entry.seq), %{content: "v2"})

    {:ok, _} = Tasks.transition(scope, ctx.task.ident, :in_progress)
    {:ok, _} = Tasks.transition(scope, ctx.task.ident, :done)

    assert Repo.get!(Entry, entry.id).source_run_id == run_id
    assert Repo.get!(Entry, revised.id).source_run_id == run_id

    assert [nil, ^run_id, ^run_id] =
             Repo.all(
               from(e in TaskEvent,
                 where: e.task_id == ^ctx.task.id,
                 order_by: [asc: e.id],
                 select: e.source_run_id
               )
             )

    {:ok, web} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "web"})
    assert Repo.get!(Entry, web.id).source_run_id == nil

    mcp_scope = %{
      token_scope_fixture(ctx.alice, ctx.workspace, :mcp)
      | actor: agent_fixture(ctx.workspace, ctx.alice, "keel/ext")
    }

    {:ok, mcp} = Feedback.add(mcp_scope, ctx.task.ident, %{content: "mcp"})
    assert Repo.get!(Entry, mcp.id).source_run_id == nil
  end
end
