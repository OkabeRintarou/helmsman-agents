defmodule Helmsman.Runs.ReadTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Agents, Runs}

  setup do
    ctx = dispatch_fixture()
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.merge(ctx, %{viewer_scope: viewer_scope, task: task})
  end

  test "a viewer lists a task's runs, newest first, and reads one", ctx do
    first = run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :succeeded})
    second = run_fixture(ctx.agent, %{task_id: ctx.task.id})

    assert {:ok, [%{id: a}, %{id: b}]} = Runs.list_for_task(ctx.viewer_scope, ctx.task.ident)
    assert {a, b} == {second.id, first.id}

    assert {:ok, %{id: id, task: ident, agent: "keel/dev", status: "succeeded", lane: "work"}} =
             Runs.get(ctx.viewer_scope, first.id)

    assert {id, ident} == {first.id, ctx.task.ident}
    assert {:error, :not_found} = Runs.list_for_task(ctx.viewer_scope, "NOPE-1")
  end

  test "another workspace's runs are not found", ctx do
    bob = user_fixture()
    other = workspace_fixture(bob)
    bob_scope = workspace_scope_fixture(bob, other)
    managed_agent_fixture(bob_scope, %{name: "other/dev"})
    other_project = project_fixture(bob_scope)
    other_task = task_fixture(bob_scope, other_project.key)
    run = run_fixture(agent_actor(other, "other/dev"), %{task_id: other_task.id})

    assert {:error, :not_found} = Runs.get(ctx.alice_scope, run.id)
    assert {:error, :not_found} = Runs.list_for_task(ctx.alice_scope, other_task.ident)
    assert {:error, :not_found} = Runs.list_for_agent(ctx.alice_scope, "other/dev")
  end

  test "an agent's runs page by (inserted_at, id) without gaps or repeats", ctx do
    at = DateTime.utc_now()

    ids =
      for n <- 1..7 do
        # Pairs share their time: the ID breaks the tie.
        inserted_at = DateTime.add(at, div(n, 2), :second)
        run_fixture(ctx.agent, %{status: :succeeded, inserted_at: inserted_at}).id
      end

    pages =
      Stream.unfold(nil, fn
        :done ->
          nil

        before ->
          {:ok, page} =
            Runs.list_for_agent(ctx.viewer_scope, "keel/dev", limit: 3, before: before)

          case page do
            [] -> nil
            page -> {page, if(length(page) < 3, do: :done, else: cursor(List.last(page)))}
          end
      end)
      |> Enum.to_list()

    expected =
      Repo.all(
        from(r in Helmsman.Runs.Run,
          where: r.id in ^ids,
          order_by: [desc: r.inserted_at, desc: r.id],
          select: r.id
        )
      )

    assert pages |> List.flatten() |> Enum.map(& &1.id) == expected
    assert length(pages) == 3
  end

  defp cursor(summary), do: {summary.inserted_at, summary.id}

  test "agent views count active and queued runs in one query", ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/review"})
    review = agent_actor(ctx.workspace, "keel/review")
    run_fixture(ctx.agent, %{task_id: ctx.task.id})
    run_fixture(ctx.agent, %{status: :running})
    run_fixture(ctx.agent, %{status: :cancelling})
    run_fixture(ctx.agent, %{status: :succeeded})
    run_fixture(review, %{status: :deferred, task_id: ctx.task.id})

    ref = make_ref()
    parent = self()
    handler = "runs-count-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:helmsman, :repo, :query],
      fn _event, _measure, meta, _config ->
        if meta[:source] == "runs" and self() == parent, do: send(parent, {ref, :runs_query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, agents} = Agents.list(ctx.viewer_scope)
    assert_receive {^ref, :runs_query}
    refute_receive {^ref, :runs_query}

    by_name = Map.new(agents, &{&1.name, &1})
    assert %{active_runs: 2, queued_runs: 1} = by_name["keel/dev"]
    assert %{active_runs: 0, queued_runs: 1} = by_name["keel/review"]

    assert {:ok, %{active_runs: 2, queued_runs: 1}} = Agents.get(ctx.viewer_scope, "keel/dev")
  end
end
