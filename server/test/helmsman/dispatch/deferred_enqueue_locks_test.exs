defmodule Helmsman.Dispatch.DeferredEnqueueLocksTest do
  # add-dependency-dispatch 1.4: the paths that enqueue assignment
  # triggers hold the workspace graph lock (pg_locks). On committed
  # connections: in the sandbox a transaction-level lock lasts until the
  # end of the test.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.DependencyFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{CommittedData, Locks, Repo, Runs, Tasks, Tx}
  alias Helmsman.Runs.{Outcome, Run}
  alias Helmsman.Tasks.TaskEvent

  @moduletag timeout: 60_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dependency_fixture()
        {carol, carol_scope} = member_scope_fixture(ctx.workspace, :admin)
        {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "in_progress")
        Map.merge(ctx, %{carol: carol, carol_scope: carol_scope})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.carol.id]) end)
    ctx
  end

  defp graph_held?(workspace_id) do
    key = Locks.key(:graph, workspace_id)

    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() " <>
          "AND granted AND ((classid::bigint << 32) | objid::bigint) = $1",
        [key]
      )

    n > 0
  end

  # Runs `fun` committed, reporting at the hook `point` whether the graph
  # lock is held.
  defp at(ctx, point, fun) do
    parent = self()

    CommittedData.unboxed(fn ->
      Process.put(:helmsman_test_hook, fn
        ^point -> send(parent, {:graph_held, point, graph_held?(ctx.workspace.id)})
        _other -> :ok
      end)

      try do
        fun.()
      after
        Process.delete(:helmsman_test_hook)
      end
    end)
  end

  defp settle(task) do
    CommittedData.unboxed(fn ->
      Tx.run(fn ->
        {:ok, Runs.cancel_pending(from(r in Run, where: r.task_id == ^task.id), :obsolete)}
      end)
    end)
  end

  defp committed(fun), do: CommittedData.unboxed(fun)

  test "update/4 with an assignee holds it when it enqueues; without one, not", ctx do
    assert {:ok, %{dispatch: [%Outcome{result: :deferred}]}} =
             at(ctx, :dependencies_read, fn ->
               Tasks.update(ctx.alice_scope, ctx.web2.ident, %{assignee: "keel/dev"})
             end)

    assert_received {:graph_held, :dependencies_read, true}

    {:ok, _} =
      at(ctx, :version_checked, fn ->
        Tasks.update(ctx.alice_scope, ctx.web2.ident, %{title: "Renamed"})
      end)

    assert_received {:graph_held, :version_checked, false}

    {:ok, _} =
      at(ctx, :version_checked, fn ->
        Tasks.update(ctx.alice_scope, ctx.web2.ident, %{assignee: nil})
      end)

    assert_received {:graph_held, :version_checked, true}
  end

  test "create/3 without an epic does not take it", ctx do
    {:ok, _} =
      at(ctx, :assignee_locked, fn ->
        Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "T", assignee: "keel/dev"})
      end)

    assert_received {:graph_held, :assignee_locked, false}
  end

  test "transition/4 and auto_reopen/2 hold it when they enqueue", ctx do
    {:ok, _} =
      committed(fn -> Tasks.update(ctx.alice_scope, ctx.web2.ident, %{assignee: "keel/dev"}) end)

    settle(ctx.web2)
    committed(fn -> put_status!(ctx.web2, :done) end)

    assert {:ok, %{dispatch: [%Outcome{trigger: :reopen, result: :deferred}]}} =
             at(ctx, :dependencies_read, fn ->
               Tasks.transition(ctx.carol_scope, ctx.web2.ident, "in_progress")
             end)

    assert_received {:graph_held, :dependencies_read, true}

    settle(ctx.web2)

    event_id =
      committed(fn ->
        put_status!(ctx.web2, :verified)

        Repo.insert!(%TaskEvent{
          workspace_id: ctx.workspace.id,
          task_id: ctx.web2.id,
          from_status: :done,
          to_status: :verified,
          actor_id: ctx.carol_scope.actor.id,
          commits: []
        }).id
      end)

    assert {:ok, %{dispatch: [%Outcome{trigger: :reopen, result: :deferred}]}} =
             at(ctx, :dependencies_read, fn ->
               Tasks.auto_reopen(ctx.web2.id, %{
                 verification_event_id: event_id,
                 reason: :ci_failed,
                 content: "CI failed."
               })
             end)

    assert_received {:graph_held, :dependencies_read, true}
  end
end
