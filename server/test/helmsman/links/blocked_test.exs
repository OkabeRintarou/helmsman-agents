defmodule Helmsman.Links.BlockedTest do
  use Helmsman.DataCase, async: true
  use ExUnitProperties

  import Helmsman.LinksFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Links, QueryCount, Tasks}
  alias Helmsman.Links.Link
  alias Helmsman.Tasks.{Task, TaskEvent, TransitionContext}

  @no_evidence %{comment: nil, commits: [], tests: nil}

  defp event_count(%{id: id}),
    do: Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^id), :count)

  defp blocked?(scope, ident) do
    {:ok, task} = Tasks.get(scope, ident)
    Tasks.summary(task).blocked
  end

  describe "blocked (task-links: 依赖满足与被阻塞)" do
    setup do
      ctx = links_fixture()
      Map.merge(ctx, %{bos: tasks!(ctx.alice, "BOS", 3), web: tasks!(ctx.alice, "WEB", 2)})
    end

    test "a blocked task cannot start; nothing is written or sent", ctx do
      %{alice: alice, keel: keel, web: [_, web2]} = ctx
      {:ok, _} = Tasks.transition(alice, "BOS-1", "in_progress")
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      count = event_count(web2)
      Events.subscribe(Events.topic(:project, web2.project_id))
      Events.subscribe(Events.topic(:task, web2.id))

      assert Tasks.transition(keel, "WEB-2", "in_progress") == {:error, {:blocked, ["BOS-1"]}}

      assert status_of(web2) == :new
      assert event_count(web2) == count
      refute_receive {:task_updated, _}
      refute_receive {:task_transitioned, _}
    end

    test "after the prerequisite is done", %{alice: alice, keel: keel} do
      {:ok, _} = Tasks.transition(alice, "BOS-1", "in_progress")
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      assert blocked?(alice, "WEB-2")

      {:ok, _} = Tasks.transition(alice, "BOS-1", "done")
      refute blocked?(alice, "WEB-2")

      assert {:ok, %{status: "in_progress", blocked: false}} =
               Tasks.transition(keel, "WEB-2", "in_progress")
    end

    test "only unsatisfied prerequisites block, listed by internal ID", ctx do
      %{alice: alice, bos: [b1, b2, b3], web: [w1, _]} = ctx
      set_status!(b1, :verified)
      set_status!(b2, :cancelled)
      set_status!(b3, :rejected)
      set_status!(w1, :done)

      for prereq <- ["WEB-1", "BOS-3", "BOS-2", "BOS-1"],
          do: {:ok, _} = Links.add(alice, "WEB-2", prereq, "depends_on")

      # A replaces link never blocks.
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "replaces")

      assert Links.blockers(task_id(alice, "WEB-2")) == ["BOS-2", "BOS-3"]

      assert Tasks.transition(alice, "WEB-2", "in_progress") ==
               {:error, {:blocked, ["BOS-2", "BOS-3"]}}
    end

    test "satisfied?/1: done and verified (no run, no repository)", %{bos: [b1 | _]} do
      for status <- Task.statuses() do
        set_status!(b1, status)
        assert Links.satisfied?(b1) == status in [:done, :verified]
        assert Links.waiting_for(b1) == if(status in [:done, :verified], do: nil, else: :status)
      end
    end

    test "a task already in progress is not stopped", %{alice: alice, web: [_, web2]} do
      {:ok, _} = Tasks.transition(alice, "WEB-2", "in_progress")
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-3", "depends_on")
      assert blocked?(alice, "WEB-2")

      assert {:ok, %{status: "done"}} = Tasks.transition(alice, "WEB-2", "done")
      # Reopening, rejecting and restoring are not checked either.
      assert {:ok, %{status: "in_progress"}} = Tasks.transition(alice, "WEB-2", "in_progress")
      assert {:ok, %{status: "rejected"}} = Tasks.transition(alice, "WEB-2", "rejected")
      assert {:ok, %{status: "new"}} = Tasks.transition(alice, "WEB-2", "new")
      assert status_of(web2) == :new
    end

    test "the check context reads blockers for new → in_progress only", ctx do
      %{alice: alice, web: [_, web2]} = ctx
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      web2 = Repo.reload!(web2)

      assert %{blockers: ["BOS-1"]} =
               TransitionContext.build(web2, alice, :in_progress, @no_evidence)

      for to <- [:rejected, :cancelled] do
        assert %{blockers: []} = TransitionContext.build(web2, alice, to, @no_evidence)
      end

      assert %{blockers: []} =
               TransitionContext.build(%{web2 | status: :done}, alice, :in_progress, @no_evidence)
    end

    test "summaries carry blocked: list, list_assigned, get and writes", ctx do
      %{alice: alice} = ctx
      {:ok, _} = Tasks.transition(alice, "WEB-1", "in_progress")
      {:ok, detail} = Links.add(alice, "WEB-1", "BOS-1", "depends_on")
      assert detail.blocked

      {:ok, tasks} = Tasks.list(alice, "WEB")
      assert %{"WEB-1" => true, "WEB-2" => false} = Map.new(tasks, &{&1.ident, &1.blocked})

      {:ok, [summary]} = Tasks.list_assigned(alice)
      assert %{id: "WEB-1", blocked: true} = summary

      {:ok, task} = Tasks.update(alice, "WEB-1", %{title: "Renamed"})
      assert Tasks.summary(task).blocked
    end
  end

  defp task_id(scope, ident),
    do: Repo.get_by!(Task, ident: ident, workspace_id: scope.workspace.id).id

  test "a run's automatic claim does not check dependencies" do
    ctx = dispatch_fixture()
    [prereq, task] = for _ <- 1..2, do: task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Links.add(ctx.alice_scope, task.ident, prereq.ident, "depends_on")
    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/dev", start: false})
    assert blocked?(ctx.alice_scope, task.ident)

    run = run_fixture(ctx.agent, %{task_id: task.id, status: :running})
    assert Tasks.auto_claim_for_run(run) == {:ok, :claimed}
    assert status_of(task) == :in_progress
  end

  describe "one definition of satisfied" do
    setup do
      ctx = links_fixture()
      Map.put(ctx, :tasks, tasks!(ctx.alice, "BOS", 6))
    end

    property "blocked in the list's SQL equals satisfied?/1 over the links", ctx do
      %{alice: alice, tasks: tasks} = ctx
      n = length(tasks)

      check all statuses <- list_of(member_of(Task.statuses()), length: n),
                edges <-
                  list_of(tuple({integer(0..(n - 1)), integer(0..(n - 1))}), max_length: 20),
                max_runs: 50 do
        Repo.delete_all(Link)

        tasks =
          tasks
          |> Enum.zip(statuses)
          |> Enum.map(fn {task, status} ->
            set_status!(task, status)
            %{task | status: status}
          end)

        edges = edges |> Enum.uniq() |> Enum.reject(fn {a, b} -> a == b end)

        Repo.insert_all(
          Link,
          Enum.map(edges, fn {a, b} ->
            %{
              workspace_id: alice.workspace.id,
              from_task_id: Enum.at(tasks, a).id,
              to_task_id: Enum.at(tasks, b).id,
              type: :depends_on,
              actor_id: alice.actor.id
            }
          end)
        )

        expected =
          tasks
          |> Enum.with_index()
          |> Map.new(fn {task, i} ->
            prereqs = for {^i, b} <- edges, do: Enum.at(tasks, b)
            {task.ident, Enum.any?(prereqs, &(not Links.satisfied?(&1)))}
          end)

        {:ok, listed} = Tasks.list(alice, "BOS", limit: 200)
        assert Map.new(listed, &{&1.ident, &1.blocked}) == expected

        assert Map.new(Links.put_blocked(tasks), &{&1.ident, &1.blocked}) == expected

        for task <- tasks, do: assert(Links.blockers(task.id) != [] == expected[task.ident])
      end
    end
  end

  test "listing 50 tasks: as many queries with links as without" do
    ctx = links_fixture()
    tasks = tasks!(ctx.alice, "BOS", 50)
    [prereq] = tasks!(ctx.alice, "WEB", 1)

    {{:ok, plain}, without} = QueryCount.count(fn -> Tasks.list(ctx.alice, "BOS", limit: 50) end)
    assert length(plain) == 50
    refute Enum.any?(plain, & &1.blocked)

    Repo.insert_all(
      Link,
      Enum.map(tasks, fn task ->
        %{
          workspace_id: ctx.workspace.id,
          from_task_id: task.id,
          to_task_id: prereq.id,
          type: :depends_on,
          actor_id: ctx.alice.actor.id
        }
      end)
    )

    {{:ok, linked}, with_links} =
      QueryCount.count(fn -> Tasks.list(ctx.alice, "BOS", limit: 50) end)

    assert Enum.all?(linked, & &1.blocked)
    assert with_links == without
  end
end
