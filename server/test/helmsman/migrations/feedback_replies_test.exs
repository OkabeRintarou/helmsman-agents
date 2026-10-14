defmodule Helmsman.Migrations.FeedbackRepliesTest do
  use Helmsman.DataCase, async: true
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  alias Helmsman.Feedback

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, root} = Feedback.add(ctx.alice_scope, task.ident, %{content: "root"})
    Map.merge(ctx, %{task: task, root: root})
  end

  defp insert(ctx, reply_to, reply_root) do
    Repo.query(
      "INSERT INTO feedback (workspace_id,task_id,seq,thread_seq,author_id,kind,content,reply_to_seq,reply_root_seq) VALUES ($1,$2,2,2,$3,'comment','reply',$4,$5)",
      [ctx.workspace.id, ctx.task.id, ctx.alice_scope.actor.id, reply_to, reply_root]
    )
  end

  test "database refuses partial, self and forward reply references", ctx do
    for {target, root} <- [{1, nil}, {nil, 1}, {2, 1}, {3, 1}, {1, 2}, {0, 0}] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               insert(ctx, target, root)
    end

    assert {:ok, _} = insert(ctx, 1, 1)
  end

  test "a target sequence from a different task is not a valid foreign key", ctx do
    other = task_fixture(ctx.alice_scope, ctx.project.key)
    ctx = %{ctx | task: other}

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             insert(ctx, 1, 1)
  end
end
