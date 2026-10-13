defmodule Helmsman.Dispatch.DeferredEnqueueTest do
  # add-dependency-dispatch 1.4: assignment triggers for a blocked task
  # create deferred runs; other triggers do not wait (decision 4); the
  # callers hold the workspace graph lock.
  use Helmsman.DataCase, async: true

  import Helmsman.DependencyFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Dispatch, Feedback, Links, Locks, Runs, Tasks, Tx}
  alias Helmsman.Runs.{Origin, Outcome, Run}

  setup do
    ctx = dependency_fixture()
    {carol, carol_scope} = member_scope_fixture(ctx.workspace, :admin)
    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "in_progress")
    Map.merge(ctx, %{carol: carol, carol_scope: carol_scope})
  end

  defp assign(ctx, task), do: Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/dev"})

  defp settle(task) do
    Tx.run(fn ->
      {:ok, Runs.cancel_pending(from(r in Run, where: r.task_id == ^task.id), :obsolete)}
    end)
  end

  # Enqueues `kind` for keel/dev on `task` as alice, under the graph lock.
  defp enqueue(ctx, task, kind) do
    {:ok, outcome} =
      Tx.run(fn ->
        :ok = Locks.graph!(ctx.workspace.id)

        Runs.enqueue(
          Origin.from_scope(ctx.alice_scope),
          %{agent: ctx.agent, profile: profile(ctx.agent), task: task, lane: :work},
          %{kind: kind, instructions: nil}
        )
      end)

    outcome
  end

  describe "被依赖阻塞的指派延后运行" do
    test "指派给被阻塞的任务", ctx do
      assert {:ok, task} = assign(ctx, ctx.web2)

      assert [%Outcome{agent: "keel/dev", result: :deferred, blocked_by: [b1], run_id: id}] =
               task.dispatch

      assert b1 == ctx.bos1.ident

      assert [%Run{id: ^id, lane: :work, triggers: [%{"kind" => "assign"} = t]}] =
               runs_in(ctx.web2, :deferred)

      assert t["blocked_by"] == [ctx.bos1.ident]
      assert runs_in(ctx.web2, :queued) == []

      assert Outcome.view(hd(task.dispatch)) == %{
               agent: "keel/dev",
               trigger: "assign",
               result: "deferred",
               reason: nil,
               blocked_by: [ctx.bos1.ident]
             }
    end

    test "依赖已满足", ctx do
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "done")

      assert {:ok, %{dispatch: [%Outcome{result: :queued, blocked_by: nil}]}} =
               assign(ctx, ctx.web2)

      assert [%Run{triggers: [t]}] = runs_in(ctx.web2, :queued)
      refute Map.has_key?(t, "blocked_by")
    end

    test "打回时依赖未满足", ctx do
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "done")
      {:ok, _} = assign(ctx, ctx.web2)
      settle(ctx.web2)
      put_status!(ctx.web2, :done)
      bos3 = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Links.add(ctx.alice_scope, ctx.web2.ident, bos3.ident, "depends_on")

      assert {:ok, %{status: "in_progress", dispatch: [outcome]}} =
               Tasks.transition(ctx.carol_scope, ctx.web2.ident, "in_progress")

      assert %Outcome{trigger: :reopen, result: :deferred, blocked_by: [b3]} = outcome
      assert b3 == bos3.ident

      assert [%Run{triggers: [%{"kind" => "reopen", "blocked_by" => [^b3]}]}] =
               runs_in(ctx.web2, :deferred)
    end
  end

  describe "不受依赖约束的触发" do
    test "被阻塞后手动运行", ctx do
      {:ok, _} = assign(ctx, ctx.web2)
      [deferred] = runs_in(ctx.web2, :deferred)

      assert {:ok, %{outcome: %Outcome{result: :merged, run_id: id}}} =
               Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.web2.ident, nil)

      assert id == deferred.id
      assert [%Run{id: ^id, triggers: triggers}] = runs_in(ctx.web2, :queued)
      assert Enum.map(triggers, & &1["kind"]) == ["assign", "manual"]
      assert runs_in(ctx.web2, :deferred) == []
    end

    test "回答不延后", ctx do
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "done")
      {:ok, _} = assign(ctx, ctx.web2)
      [assign_run] = runs_in(ctx.web2, :queued)
      settle(ctx.web2)

      run =
        run_fixture(ctx.agent, %{
          task_id: ctx.web2.id,
          status: :running,
          triggers: assign_run.triggers,
          capabilities: ["read", "write_task"]
        })

      {scope, _token} = run_scope_fixture(run)
      {:ok, _q} = Feedback.add(scope, ctx.web2.ident, %{kind: "question", content: "?"})
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: :succeeded])

      bos3 = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Links.add(ctx.alice_scope, ctx.web2.ident, bos3.ident, "depends_on")

      {:ok, answer} =
        Feedback.add(ctx.alice_scope, ctx.web2.ident, %{kind: "answer", content: "!"})

      assert [%{trigger: "answer", result: "queued", run_id: id}] = Feedback.view(answer).dispatch
      assert %Run{status: :queued, triggers: [%{"assignee_bound" => true}]} = Repo.get!(Run, id)
    end
  end

  describe "merging" do
    test "a deferred run takes a gated trigger whose dependencies are satisfied: queued", ctx do
      {:ok, _} = assign(ctx, ctx.web2)
      [deferred] = runs_in(ctx.web2, :deferred)
      put_status!(ctx.bos1, :done)

      assert %Outcome{result: :merged, run_id: id} = enqueue(ctx, Repo.reload!(ctx.web2), :reopen)
      assert id == deferred.id
      assert %Run{status: :queued, triggers: [_, %{"kind" => "reopen"} = t]} = Repo.get!(Run, id)
      refute Map.has_key?(t, "blocked_by")
    end

    test "a deferred run takes another blocked gated trigger: still deferred", ctx do
      {:ok, _} = assign(ctx, ctx.web2)
      [deferred] = runs_in(ctx.web2, :deferred)

      assert %Outcome{result: :deferred, blocked_by: [_], run_id: id} =
               enqueue(ctx, Repo.reload!(ctx.web2), :reopen)

      assert id == deferred.id
      assert run_status(deferred) == :deferred
    end

    test "a queued run takes a blocked gated trigger: stays queued, merged", ctx do
      run = run_with!(ctx, ctx.web2, :queued, ["manual"])

      assert %Outcome{result: :merged, blocked_by: nil, run_id: id} =
               enqueue(ctx, Repo.reload!(ctx.web2), :assign)

      assert id == run.id
      assert %Run{status: :queued, triggers: [_, %{"blocked_by" => [_]}]} = Repo.get!(Run, id)
    end

    test "the ON CONFLICT branch follows the same rules", ctx do
      web2 = Repo.reload!(ctx.web2)

      # Another writer inserts the same key first (as a caller without the
      # task lock may): the statement takes the conflict branch.
      insert_first = fn status ->
        Process.put(:helmsman_test_hook, fn
          :before_insert ->
            Process.delete(:helmsman_test_hook)
            run_with!(ctx, web2, status, ["assign"])

          _other ->
            :ok
        end)
      end

      insert_first.(:deferred)
      assert %Outcome{result: :deferred, blocked_by: [_]} = enqueue(ctx, web2, :assign)
      assert [%Run{triggers: [_, _]}] = runs_in(web2, :deferred)

      settle(web2)
      insert_first.(:deferred)
      assert %Outcome{result: :merged} = enqueue(ctx, web2, :manual)
      assert [%Run{triggers: [_, %{"kind" => "manual"}]}] = runs_in(web2, :queued)
      assert runs_in(web2, :deferred) == []

      settle(web2)
      insert_first.(:queued)
      assert %Outcome{result: :merged} = enqueue(ctx, web2, :assign)
      assert [%Run{}] = runs_in(web2, :queued)
      assert runs_in(web2, :deferred) == []
    end
  end
end
