defmodule Helmsman.Tasks.SelfVerifySquadTest do
  # add-squads 3.1: self-verification on the assignee side of a squad's
  # task (task-status "自验收规则", decision 11).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.Tasks
  alias HelmsmanMCP.{Pipeline, Sessions}

  @tests %{command: "mix test", passed: true, summary: "12 tests, 0 failures"}

  setup do
    ctx = squads_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "web-team", start: false})
    Map.put(ctx, :task, task)
  end

  defp run_scope(ctx, agent, attrs \\ %{}) do
    run =
      run_fixture(
        agent,
        Map.merge(
          %{
            task_id: ctx.task.id,
            status: :running,
            root_initiator_user_id: ctx.alice.id,
            capabilities: ["read", "write_task"]
          },
          attrs
        )
      )

    {scope, _token} = run_scope_fixture(run)
    scope
  end

  defp leader_scope(ctx),
    do:
      run_scope(ctx, ctx.lead, %{
        squad_id: ctx.squad.id,
        capabilities: ["read", "write_task", "create_tasks", "delegate"]
      })

  # The leader moves it to done, with `opts`.
  # The leader's run then ends.
  defp done(ctx, opts \\ %{}) do
    scope = leader_scope(ctx)
    {:ok, _} = Tasks.transition(scope, ctx.task.ident, :in_progress)
    {:ok, _} = Tasks.transition(scope, ctx.task.ident, :done, opts)

    Repo.update_all(from(r in Helmsman.Runs.Run, where: r.id == ^scope.run.id),
      set: [status: :succeeded, finished_at: DateTime.utc_now()]
    )
  end

  defp status(ctx), do: Repo.get!(Helmsman.Tasks.Task, ctx.task.id).status

  test "the review member without tests", ctx do
    done(ctx)

    assert {:error, {:self_verify_requires_tests, "web-team"}} =
             Tasks.transition(run_scope(ctx, ctx.review), ctx.task.ident, :verified)

    assert status(ctx) == :done
  end

  test "a person in the squad without tests", ctx do
    done(ctx)

    assert {:error, {:self_verify_requires_tests, "web-team"}} =
             Tasks.transition(ctx.bob_scope, ctx.task.ident, :verified)
  end

  test "the leader itself, then with tests", ctx do
    done(ctx)
    scope = leader_scope(ctx)

    assert {:error, {:self_verify_requires_tests, "web-team"}} =
             Tasks.transition(scope, ctx.task.ident, :verified)

    assert {:ok, _} = Tasks.transition(scope, ctx.task.ident, :verified, %{tests: @tests})
  end

  test "tests passed when done count for the member", ctx do
    done(ctx, %{tests: @tests})
    assert {:ok, _} = Tasks.transition(run_scope(ctx, ctx.review), ctx.task.ident, :verified)
  end

  test "someone outside the squad: no tests needed", ctx do
    done(ctx)
    assert {:ok, _} = Tasks.transition(ctx.carol_scope, ctx.task.ident, :verified)
  end

  test "the owner of a member is not on the side", ctx do
    # alice owns every agent of the squad but is not in it.
    done(ctx)
    assert {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :verified)
  end

  test "MCP: the English text names the assignee side and the squad", ctx do
    done(ctx)
    scope = run_scope(ctx, ctx.review)
    sid = "test-#{System.unique_integer([:positive])}"
    :ok = Sessions.register(sid, scope, self())

    assert {:error, text} =
             Pipeline.call_tool(
               "transition_task",
               %{"task_id" => ctx.task.ident, "to" => "verified"},
               scope,
               sid
             )

    assert text ==
             "You are on the assignee side of #{ctx.task.ident} (squad web-team). " <>
               "Pass tests={passed: true, ...} or let the requester verify."
  end
end
