defmodule Helmsman.Dispatch.ObsoleteDeferredTest do
  # add-dependency-dispatch 1.8: deferred runs are never claimed, so they
  # are cancelled where they become obsolete (decision 8).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.DependencyFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Links, Tasks}
  alias Helmsman.Runs.Run

  setup do
    ctx = dependency_fixture()
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/ops"})
    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "in_progress")
    {:ok, _} = Tasks.update(ctx.alice_scope, ctx.web2.ident, %{assignee: "keel/dev"})
    [deferred] = runs_in(ctx.web2, :deferred)
    Map.merge(ctx, %{deferred: deferred, ops: agent_actor(ctx.workspace, "keel/ops")})
  end

  defp cancelled_obsolete?(run),
    do: match?(%Run{status: :cancelled, failure_reason: :obsolete}, Repo.get!(Run, run.id))

  describe "失效的延后运行" do
    test "改派", ctx do
      {:ok, task} = Tasks.update(ctx.alice_scope, ctx.web2.ident, %{assignee: "keel/ops"})

      assert cancelled_obsolete?(ctx.deferred)
      assert [%{agent: "keel/ops", result: :deferred}] = task.dispatch
      assert [%Run{agent_id: ops_id}] = runs_in(ctx.web2, :deferred)
      assert ops_id == ctx.ops.id
    end

    test "unassigned: cancelled too", ctx do
      {:ok, _} = Tasks.update(ctx.alice_scope, ctx.web2.ident, %{assignee: nil})
      assert cancelled_obsolete?(ctx.deferred)
    end

    test "任务撤销", ctx do
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.web2.ident, "cancelled")
      assert cancelled_obsolete?(ctx.deferred)
    end

    test "verified", ctx do
      put_status!(ctx.web2, :done)
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.web2.ident, "verified")
      assert cancelled_obsolete?(ctx.deferred)
    end

    test "replaced (cancelled by a replacing task)", ctx do
      other = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Links.add(ctx.alice_scope, other.ident, ctx.web2.ident, "replaces")
      assert status_of(ctx.web2) == :cancelled
      assert cancelled_obsolete?(ctx.deferred)
    end

    test "queued runs and runs of other lanes or triggers are left alone", ctx do
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      queued = run_with!(ctx, task, :queued, ["assign"])
      reply = run_with!(ctx, ctx.web2, :queued, ["mention"], %{lane: :reply})
      reply_deferred = run_with!(ctx, task, :deferred, ["mention"], %{lane: :reply})
      put_assignee!(task, ctx.agent.id)

      {:ok, _} = Tasks.update(ctx.alice_scope, ctx.web2.ident, %{assignee: "keel/ops"})
      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/ops"})
      {:ok, _} = Tasks.transition(ctx.alice_scope, task.ident, "cancelled")

      assert cancelled_obsolete?(ctx.deferred)
      assert run_status(queued) == :queued
      assert run_status(reply) == :queued
      assert run_status(reply_deferred) == :deferred
    end
  end

  defp status_of(task), do: Repo.reload!(task).status
end
