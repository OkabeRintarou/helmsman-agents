defmodule Helmsman.Migrations.RunSteersTest do
  # add-run-steering 1.1: `run_steers` (decision 2).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Feedback

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run = run_fixture(ctx.agent, %{task_id: task.id, status: :running})
    {:ok, entry} = Feedback.add(ctx.alice_scope, task.ident, %{content: "x"})
    Map.merge(ctx, %{task: task, run: run, entry: entry})
  end

  defp insert(workspace_id, run_id, feedback_id) do
    Repo.query(
      "INSERT INTO run_steers (workspace_id, run_id, feedback_id, sent_at) VALUES ($1, $2, $3, now())",
      [workspace_id, run_id, feedback_id]
    )
  end

  test "a run of another workspace is refused by the foreign key", ctx do
    other = dispatch_fixture()
    other_task = task_fixture(other.alice_scope, other.project.key)
    other_run = run_fixture(other.agent, %{task_id: other_task.id})

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             insert(ctx.workspace.id, other_run.id, ctx.entry.id)

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             insert(other.workspace.id, other_run.id, ctx.entry.id)
  end

  test "the same (run_id, feedback_id) twice is refused by the primary key", ctx do
    assert {:ok, _} = insert(ctx.workspace.id, ctx.run.id, ctx.entry.id)

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             insert(ctx.workspace.id, ctx.run.id, ctx.entry.id)
  end

  test "feedback_id is indexed" do
    %{rows: rows} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = 'run_steers'")

    assert Enum.any?(List.flatten(rows), &(&1 =~ "(feedback_id)"))
  end
end
