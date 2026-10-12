defmodule Helmsman.Tasks.TransitionActiveRunTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task

  setup do
    ctx = dispatch_fixture()
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/review"})
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [status: :done])
    Map.merge(ctx, %{task: task, review: agent_actor(ctx.workspace, "keel/review")})
  end

  test "another run still running: run_active, status unchanged", ctx do
    for status <- [:claimed, :running, :cancelling] do
      run = run_fixture(ctx.agent, %{task_id: ctx.task.id, status: status})
      id = run.id

      assert {:error, {:run_active, %{id: ^id, agent: "keel/dev"}}} =
               Tasks.transition(ctx.alice_scope, ctx.task.ident, :verified)

      assert Repo.get!(Task, ctx.task.id).status == :done
      Repo.delete!(run)
    end
  end

  test "the earliest active run is reported", ctx do
    first = run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :running})
    run_fixture(ctx.review, %{task_id: ctx.task.id, status: :running})
    id = first.id

    assert {:error, {:run_active, %{id: ^id}}} =
             Tasks.transition(ctx.alice_scope, ctx.task.ident, :verified)
  end

  test "the reviewer verifying in its own run", ctx do
    run =
      run_fixture(ctx.review, %{
        task_id: ctx.task.id,
        status: :running,
        capabilities: ["read", "write_task"]
      })

    {scope, _token} = run_scope_fixture(run)
    assert {:ok, %{status: "verified"}} = Tasks.transition(scope, ctx.task.ident, :verified)
  end

  test "queued, deferred and ended runs do not count", ctx do
    run_fixture(ctx.agent, %{task_id: ctx.task.id})
    run_fixture(ctx.review, %{task_id: ctx.task.id, status: :deferred})

    for status <- [:succeeded, :failed, :cancelled],
        do: run_fixture(ctx.agent, %{task_id: ctx.task.id, status: status})

    assert {:ok, %{status: "verified"}} =
             Tasks.transition(ctx.alice_scope, ctx.task.ident, :verified)
  end
end
