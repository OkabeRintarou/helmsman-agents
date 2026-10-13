defmodule Helmsman.Links.ReplacesTest do
  use Helmsman.DataCase, async: true

  import Helmsman.LinksFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Links, Runs, Tasks}
  alias Helmsman.Links.Link
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.TaskEvent

  defp last_event(%{id: id}) do
    Repo.one!(
      from(e in TaskEvent,
        where: e.task_id == ^id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1,
        preload: :actor
      )
    )
  end

  defp event_count(%{id: id}),
    do: Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^id), :count)

  describe "replacing (task-links: 替代与自动撤销)" do
    setup do
      ctx = links_fixture()
      Map.put(ctx, :bos, tasks!(ctx.alice, "BOS", 5))
    end

    test "a task in progress is cancelled", %{alice: alice, bos: bos} do
      b2 = Enum.at(bos, 1)
      {:ok, _} = Tasks.transition(alice, "BOS-2", "in_progress")

      assert {:ok,
              %{id: "BOS-5", links: [%{type: "replaces", task: "BOS-2", status: "cancelled"}]}} =
               Links.add(alice, "BOS-5", "BOS-2", "replaces")

      assert status_of(b2) == :cancelled
      event = last_event(b2)
      assert {event.from_status, event.to_status} == {:in_progress, :cancelled}
      assert event.actor.id == alice.actor.id
      assert event.auto
      assert event.comment == "replaced by BOS-5"
      assert event.source_run_id == nil
    end

    test "a new task is cancelled", %{alice: alice, bos: bos} do
      b2 = Enum.at(bos, 1)
      {:ok, _} = Links.add(alice, "BOS-5", "BOS-2", "replaces")
      assert status_of(b2) == :cancelled
      assert %{from_status: :new, to_status: :cancelled, auto: true} = last_event(b2)
    end

    test "a task in another status only gets the link", %{alice: alice, bos: bos} do
      [b1, b2, b3, b4, _b5] = bos

      for {task, status} <- [{b1, :done}, {b2, :verified}, {b3, :rejected}, {b4, :cancelled}] do
        set_status!(task, status)
        count = event_count(task)
        assert {:ok, _} = Links.add(alice, "BOS-5", task.ident, "replaces")
        assert status_of(task) == status
        assert event_count(task) == count
      end

      assert Repo.aggregate(Link, :count) == 4
    end

    test "adding an existing replaces link again cancels nothing", %{alice: alice, bos: bos} do
      b2 = Enum.at(bos, 1)
      set_status!(b2, :done)
      {:ok, _} = Links.add(alice, "BOS-5", "BOS-2", "replaces")
      # Reopened while the link exists (only restoring from CANCELLED is refused).
      {:ok, _} = Tasks.transition(alice, "BOS-2", "in_progress")

      assert {:ok, _} = Links.add(alice, "BOS-5", "BOS-2", "replaces")
      assert status_of(b2) == :in_progress
    end

    test "restoring a replaced task is refused until the link is removed", %{alice: alice} do
      {:ok, _} = Links.add(alice, "BOS-5", "BOS-2", "replaces")
      b2 = %{id: task_id(alice, "BOS-2")}
      count = event_count(b2)

      assert Tasks.transition(alice, "BOS-2", "new") == {:error, {:replaced, ["BOS-5"]}}
      assert event_count(b2) == count
      assert status_of(b2) == :cancelled

      {:ok, _} = Links.remove(alice, "BOS-5", "BOS-2", "replaces")
      assert {:ok, %{status: "new"}} = Tasks.transition(alice, "BOS-2", "new")
    end

    test "every replacer is listed, by internal ID", %{alice: alice} do
      {:ok, _} = Links.add(alice, "BOS-4", "BOS-2", "replaces")
      {:ok, _} = Links.add(alice, "BOS-3", "BOS-2", "replaces")
      {:ok, _} = Links.add(alice, "BOS-5", "BOS-2", "depends_on")

      assert Links.replaced_by(task_id(alice, "BOS-2")) == ["BOS-3", "BOS-4"]

      assert Tasks.transition(alice, "BOS-2", "new") ==
               {:error, {:replaced, ["BOS-3", "BOS-4"]}}
    end

    test "a rejected task with a replacer may be restored", %{alice: alice, bos: bos} do
      set_status!(Enum.at(bos, 1), :rejected)
      {:ok, _} = Links.add(alice, "BOS-5", "BOS-2", "replaces")
      assert {:ok, %{status: "new"}} = Tasks.transition(alice, "BOS-2", "new")
    end

    test "removing the link does not restore the task", %{alice: alice, bos: bos} do
      {:ok, _} = Links.add(alice, "BOS-5", "BOS-2", "replaces")
      {:ok, _} = Links.remove(alice, "BOS-5", "BOS-2", "replaces")
      assert status_of(Enum.at(bos, 1)) == :cancelled
    end

    test "the cancellation runs the transition steps, with its history entry",
         %{alice: alice, bos: bos} do
      parent = self()

      Process.put(:helmsman_extra_transition_steps, [
        fn task, event, scope ->
          send(parent, {:step, task.ident, task.status, event, scope.actor.id})
          :ok
        end
      ])

      {:ok, _} = Links.add(alice, "BOS-5", "BOS-2", "replaces")
      actor_id = alice.actor.id

      assert_received {:step, "BOS-2", :cancelled,
                       %TaskEvent{
                         from_status: :new,
                         to_status: :cancelled,
                         auto: true,
                         comment: "replaced by BOS-5"
                       }, ^actor_id}

      # A step that fails rolls the link back with the cancellation.
      Process.put(:helmsman_extra_transition_steps, [fn _, _, _ -> {:error, :boom} end])
      b3 = Enum.at(bos, 2)
      assert Links.add(alice, "BOS-5", "BOS-3", "replaces") == {:error, :boom}
      assert status_of(b3) == :new
      refute Repo.get_by(Link, to_task_id: b3.id)
    end
  end

  defp task_id(scope, ident),
    do: Repo.get_by!(Helmsman.Tasks.Task, ident: ident, workspace_id: scope.workspace.id).id

  describe "runs on the replaced task" do
    setup do
      ctx = dispatch_fixture()
      [a, b] = for _ <- 1..2, do: task_fixture(ctx.alice_scope, ctx.project.key)
      Map.merge(ctx, %{a: a, b: b})
    end

    test "a running run is not stopped", ctx do
      run = run_fixture(ctx.agent, %{task_id: ctx.b.id, status: :running})
      {:ok, _} = Links.add(ctx.alice_scope, ctx.a.ident, ctx.b.ident, "replaces")
      assert status_of(ctx.b) == :cancelled
      assert Repo.get!(Run, run.id).status == :running
    end

    test "a queued work run is cancelled as obsolete when claimed", ctx do
      run = run_fixture(ctx.agent, %{task_id: ctx.b.id})
      {:ok, _} = Links.add(ctx.alice_scope, ctx.a.ident, ctx.b.ident, "replaces")
      assert Repo.get!(Run, run.id).status == :queued

      assert Runs.claim(daemon_ctx(daemon_of(ctx.agent)), "http://localhost:4000") == {:ok, []}
      assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, run.id)
    end

    test "a run replacing its own task: the history refers to the run", ctx do
      run =
        run_fixture(ctx.agent, %{
          task_id: ctx.b.id,
          status: :running,
          capabilities: ["read", "write_task"]
        })

      {scope, _token} = run_scope_fixture(run)

      assert {:ok, _} = Links.add(scope, ctx.a.ident, ctx.b.ident, "replaces")
      assert status_of(ctx.b) == :cancelled
      event = last_event(ctx.b)
      assert event.source_run_id == run.id
      assert event.actor.id == ctx.agent.id
      assert event.auto
      assert event.comment == "replaced by #{ctx.a.ident}"
    end
  end

  describe "an epic replacing its own step (add-epics x add-task-links)" do
    setup do
      ctx = links_fixture()
      epic = task_fixture(ctx.alice, "BOS", %{kind: "epic"})
      [done, open] = for _ <- 1..2, do: task_fixture(ctx.alice, "BOS", %{epic: epic.ident})
      {:ok, _} = Tasks.transition(ctx.alice, done.ident, "in_progress")
      {:ok, _} = Tasks.transition(ctx.alice, done.ident, "done")
      Events.subscribe(Events.topic(:project, epic.project_id))
      Map.merge(ctx, %{epic: epic, done: done, open: open})
    end

    # Every project summary of `ident` received so far, oldest first.
    defp summaries(ident, acc \\ []) do
      receive do
        {:task_updated, %{id: ^ident} = summary} -> summaries(ident, [summary | acc])
      after
        100 -> Enum.reverse(acc)
      end
    end

    test "the detail and the last project summary carry the epic's new status", ctx do
      %{alice: alice, epic: %{ident: ident} = epic, open: open} = ctx

      {:ok, detail} = Links.add(alice, ident, open.ident, "replaces")

      assert status_of(epic) == :done
      assert %{status: "done", progress: %{done: 1, by_status: %{"cancelled" => 1}}} = detail
      assert %{from: "new", to: "done", auto: true} = List.last(detail.history)
      assert %{status: "done"} = List.last(summaries(ident))
      {:ok, task} = Tasks.get(alice, ident)
      assert Tasks.detail(task).status == "done"
      assert Tasks.detail(task).updated_at == detail.updated_at
    end

    test "a plain replacer is unchanged", ctx do
      %{alice: alice, epic: epic, open: open} = ctx
      [other] = tasks!(alice, "BOS", 1)

      {:ok, detail} = Links.add(alice, other.ident, open.ident, "replaces")

      assert %{id: id, status: "new"} = detail
      assert id == other.ident
      assert [%{status: "new"}] = summaries(other.ident)
      assert status_of(epic) == :done
    end

    test "a failed write notifies nothing", ctx do
      %{viewer: viewer, epic: %{ident: ident} = epic, open: open} = ctx

      assert {:error, :forbidden} = Links.add(viewer, ident, open.ident, "replaces")

      assert status_of(epic) == :new
      assert summaries(ident) == []
    end
  end
end
