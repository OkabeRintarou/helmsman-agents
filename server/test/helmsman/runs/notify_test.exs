defmodule Helmsman.Runs.NotifyTest do
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, Dispatch, Events, Tasks, Tx}
  alias Helmsman.Daemons.{Daemon, Runtime}

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    runtime = Repo.get!(Runtime, profile(ctx.agent).runtime_id)

    Events.subscribe(Events.topic(:task, task.id))
    Events.subscribe(Events.topic(:workspace_runs, ctx.workspace.id))
    Events.subscribe(Events.topic(:daemon, runtime.daemon_id))
    Map.merge(ctx, %{task: task, runtime: runtime})
  end

  defp assign(ctx), do: Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "keel/dev"})

  test "assigning: run summary, runs changed, runs available", ctx do
    {:ok, %{dispatch: [%{run_id: id}]}} = assign(ctx)
    ident = ctx.task.ident

    assert_receive {:runs_changed, ^ident}
    assert_receive {:run_updated, %{id: ^id, status: "queued", agent: "keel/dev", task: ^ident}}
    assert_receive {:runs_available}
  end

  test "merging and cancelling notify too; the daemon only about new runs", ctx do
    {:ok, %{dispatch: [%{run_id: id}]}} = assign(ctx)
    assert_receive {:run_updated, %{id: ^id}}
    assert_receive {:runs_available}

    Events.subscribe(Events.topic(:run, id))
    {:ok, _} = Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.task.ident, "more")
    assert_receive {:run_updated, %{id: ^id, triggers: [_, _]}}
    assert_receive {:run_updated, %{id: ^id, triggers: [_, _]}}
    refute_receive {:runs_available}

    {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")
    assert_receive {:run_updated, %{id: ^id, status: "cancelled"}}
    assert_receive {:runs_changed, _}
  end

  test "a revoked daemon is not told", ctx do
    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Daemon, ctx.runtime.daemon_id),
        revoked_at: DateTime.utc_now(:second)
      )
    )

    {:ok, %{dispatch: [%{result: :queued}]}} = assign(ctx)
    assert_receive {:run_updated, _}
    refute_receive {:runs_available}
  end

  test "a rollback sends nothing", ctx do
    assert {:error, :boom} =
             Tx.run(fn ->
               {:ok, _} = assign(ctx)
               {:error, :boom}
             end)

    assert runs_of(ctx.task.id) == []
    refute_receive {:run_updated, _}
    refute_receive {:runs_changed, _}
    refute_receive {:runs_available}
  end

  test "several changes in one transaction: one message each, the latest summary", ctx do
    assert {:ok, id} =
             Tx.run(fn ->
               {:ok, %{dispatch: [%{run_id: id}]}} = assign(ctx)
               {:ok, _} = Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.task.ident, "1")
               {:ok, _} = Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.task.ident, "2")
               {:ok, id}
             end)

    assert_receive {:run_updated, %{id: ^id, triggers: [_, _, _]}}
    refute_receive {:run_updated, _}
    assert_receive {:runs_changed, _}
    refute_receive {:runs_changed, _}
    assert_receive {:runs_available}
    refute_receive {:runs_available}
  end
end
