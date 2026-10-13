defmodule Helmsman.Autopilots.SettleHooksTest do
  # add-autopilots 4.2: when settling is planned (decision 8).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AutopilotsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures

  alias Helmsman.{Agents, Autopilots, Tasks}
  alias Helmsman.Autopilots.Workers.Settle
  alias Helmsman.Runs.{Retry, Run}
  alias Helmsman.Tasks.Task

  setup do
    ctx = autopilots_fixture()
    view = autopilot_fixture(ctx.alice_scope)
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    Repo.delete_all(Oban.Job)
    Map.merge(ctx, %{view: view, record: record, task: Repo.get!(Task, record.task_id)})
  end

  test "the run of its task ends (daemon report)", ctx do
    [run_id] = claim!(ctx.agent)
    assert run_id == ctx.record.run_id
    start!(ctx.agent, run_id)
    finish!(ctx.agent, run_id, :succeeded)
    assert_enqueued(worker: Settle, args: %{autopilot_id: ctx.view.id})
  end

  test "an automatic retry that will not happen", ctx do
    Repo.update_all(from(r in Run, where: r.id == ^ctx.record.run_id),
      set: [status: :failed, failure_reason: :timeout, finished_at: DateTime.utc_now()]
    )

    {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")
    Repo.delete_all(Oban.Job)
    assert {:ok, :skipped} = Retry.perform(ctx.record.run_id)
    assert_enqueued(worker: Settle, args: %{autopilot_id: ctx.view.id})
  end

  test "the task moves to done", ctx do
    Repo.update_all(from(r in Run, where: r.id == ^ctx.record.run_id), set: [status: :cancelled])
    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, "in_progress")
    refute_enqueued(worker: Settle)
    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, "done", %{"comment" => "ok"})
    assert_enqueued(worker: Settle, args: %{autopilot_id: ctx.view.id})
  end

  test "the assignee changes", ctx do
    {:ok, _} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: nil})
    assert_enqueued(worker: Settle, args: %{autopilot_id: ctx.view.id})
  end

  test "a task without a started record plans nothing", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: nil})

    {:ok, 1} =
      Helmsman.Tx.run(fn ->
        {:ok,
         Helmsman.Runs.cancel_pending(from(r in Run, where: r.task_id == ^task.id), :obsolete)}
      end)

    refute_enqueued(worker: Settle)
  end
end
