defmodule Helmsman.Runs.ClaimConcurrencyTest do
  # add-run-lifecycle 2.3: concurrent claims, each on its own connection,
  # released together by a barrier.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{CommittedData, Dispatch, Repo, Runs, Tasks}
  alias Helmsman.Runs.Run

  @base_url "http://localhost:4000"
  @rounds 20

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture(%{access: "workspace"})
        managed_agent_fixture(ctx.alice_scope, %{name: "keel/other", access: "workspace"})
        other = agent_actor(ctx.workspace, "keel/other")

        Map.merge(ctx, %{
          other: other,
          daemons: [daemon_of(ctx.agent), daemon_of(other)]
        })
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  # Runs each function on its own connection; all start together.
  defp together(funs) do
    parent = self()

    tasks = Enum.map(funs, &start_on_go(&1, parent))

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}, 5_000
        pid
      end

    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp start_on_go(fun, parent),
    do: Task.async(fn -> CommittedData.unboxed(fn -> on_go(fun, parent) end) end)

  defp on_go(fun, parent) do
    send(parent, {:ready, self()})

    receive do
      :go -> fun.()
    end
  end

  test "two daemons: every run claimed at most once, a task at most one active (scenario)",
       ctx do
    for _round <- 1..@rounds do
      runs =
        CommittedData.unboxed(fn ->
          task = task_fixture(ctx.alice_scope, ctx.project.key)

          [
            run_fixture(ctx.agent, %{task_id: task.id}),
            run_fixture(ctx.other, %{task_id: task.id})
          ]
        end)

      results =
        together(
          for daemon <- ctx.daemons, do: fn -> Runs.claim(daemon_ctx(daemon), @base_url) end
        )

      claimed_ids = Enum.flat_map(results, fn {:ok, specs} -> Enum.map(specs, & &1.run_id) end)
      assert length(claimed_ids) == length(Enum.uniq(claimed_ids))

      statuses =
        CommittedData.unboxed(fn ->
          Repo.all(from(r in Run, where: r.id in ^Enum.map(runs, & &1.id), select: r.status))
        end)

      assert Enum.count(statuses, &(&1 == :claimed)) == 1
      assert Enum.count(statuses, &(&1 == :queued)) == 1
      assert length(claimed_ids) == 1

      # The next round starts with the daemons free.
      CommittedData.unboxed(fn ->
        Repo.update_all(from(r in Run, where: r.id in ^Enum.map(runs, & &1.id)),
          set: [status: :succeeded]
        )
      end)
    end
  end

  test "a claim and an assignment of the same (task, agent): no trigger is lost", ctx do
    alice = CommittedData.unboxed(fn -> human_actor(ctx.workspace, ctx.alice) end)

    for _round <- 1..@rounds do
      task =
        CommittedData.unboxed(fn ->
          task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: alice.name})
          {:ok, _} = Dispatch.run_agent(ctx.alice_scope, "keel/dev", task.ident, "Go.")
          task
        end)

      [daemon | _] = ctx.daemons

      [{:ok, _specs}, {:ok, _task}] =
        together([
          fn -> Runs.claim(daemon_ctx(daemon), @base_url) end,
          fn -> Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/dev"}) end
        ])

      runs = CommittedData.unboxed(fn -> runs_of(task.id) end)
      kinds = runs |> Enum.flat_map(& &1.triggers) |> Enum.map(& &1["kind"]) |> Enum.sort()
      assert kinds == ["assign", "manual"]

      case Enum.map(runs, & &1.status) do
        # The assignment merged into the run before the claim (or the claim
        # skipped it while the task row was held).
        [status] -> assert status in [:queued, :claimed]
        # The run was claimed first; the assignment queued a new one.
        [:claimed, :queued] -> assert [%{"kind" => "assign"}] = List.last(runs).triggers
      end

      CommittedData.unboxed(fn ->
        Repo.update_all(from(r in Run, where: r.task_id == ^task.id),
          set: [status: :succeeded]
        )
      end)
    end
  end
end
