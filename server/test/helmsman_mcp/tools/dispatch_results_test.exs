defmodule HelmsmanMCP.Tools.DispatchResultsTest do
  # add-continuation-triggers 1.9: `dispatch` in the results of
  # transition_task, add_feedback and update_feedback, and the `busy` text
  # (decision 10).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Runs, Tx}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task
  alias HelmsmanMCP.{Context, ErrorText}
  alias HelmsmanMCP.Tools.{AddFeedback, TransitionTask, UpdateFeedback}

  setup do
    ctx = dispatch_fixture()
    {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/c"})
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})

    Tx.run(fn ->
      {:ok, Runs.cancel_pending(from(r in Run, where: r.task_id == ^task.id), :obsolete)}
    end)

    Map.merge(ctx, %{bob_scope: bob_scope, task: task})
  end

  defp context(tool, scope, args),
    do: %Context{tool: tool.name(), scope: scope, args: args, session: nil}

  defp call(tool, scope, args), do: tool.call(args, context(tool, scope, args))

  test "a send-back wakes the assignee (scenario)", ctx do
    Repo.update_all(from(t in Task, where: t.id == ^ctx.task.id), set: [status: :done])

    args = %{
      "task_id" => ctx.task.ident,
      "to" => "IN_PROGRESS",
      "feedback" => %{"kind" => "review", "content" => "Missing tests"}
    }

    assert {:ok, result} = call(TransitionTask, ctx.bob_scope, args)

    assert result.dispatch == [
             %{agent: "keel/dev", trigger: "reopen", result: "queued", reason: nil}
           ]
  end

  test "no trigger, no dispatch key", ctx do
    args = %{"task_id" => ctx.task.ident, "to" => "IN_PROGRESS"}
    assert {:ok, result} = call(TransitionTask, ctx.alice_scope, args)
    refute Map.has_key?(result, :dispatch)

    assert {:ok, result} =
             call(AddFeedback, ctx.alice_scope, %{"task_id" => ctx.task.ident, "content" => "hi"})

    refute Map.has_key?(result, :dispatch)
  end

  test "a refused mention is not an error (scenario)", ctx do
    args = %{"task_id" => ctx.task.ident, "content" => "@keel/c please check"}
    assert {:ok, result} = call(AddFeedback, ctx.bob_scope, args)
    assert result.content == "@keel/c please check"

    assert result.dispatch == [
             %{agent: "keel/c", trigger: "mention", result: "skipped", reason: "unauthorized"}
           ]
  end

  test "update_feedback reports the new mentions", ctx do
    {:ok, first} =
      call(AddFeedback, ctx.alice_scope, %{"task_id" => ctx.task.ident, "content" => "draft"})

    args = %{"feedback_id" => first.id, "content" => "@keel/c look"}
    assert {:ok, result} = call(UpdateFeedback, ctx.alice_scope, args)

    assert [%{agent: "keel/c", trigger: "mention", result: "queued", reason: nil}] =
             result.dispatch
  end

  test "busy: the task is being changed concurrently", ctx do
    for {tool, args} <- [
          {TransitionTask, %{"task_id" => "bos-1", "to" => "DONE"}},
          {AddFeedback, %{"task_id" => "bos-1", "content" => "x"}},
          {UpdateFeedback, %{"feedback_id" => "bos-1#2", "content" => "x"}}
        ] do
      assert {:ok, "Too many concurrent changes to BOS-1; try again."} =
               ErrorText.format(:busy, context(tool, ctx.alice_scope, args))
    end
  end
end
