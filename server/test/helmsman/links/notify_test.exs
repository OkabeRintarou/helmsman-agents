defmodule Helmsman.Links.NotifyTest do
  use Helmsman.DataCase, async: true

  import Helmsman.LinksFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Links, Tasks}

  defp subscribe_task(%{id: id}), do: Events.subscribe(Events.topic(:task, id))
  defp subscribe_project(%{project_id: id}), do: Events.subscribe(Events.topic(:project, id))

  describe "reading and notifications (task-links: 关联的读取与通知)" do
    setup do
      ctx = links_fixture()
      Map.merge(ctx, %{bos: tasks!(ctx.alice, "BOS", 4), web: tasks!(ctx.alice, "WEB", 2)})
    end

    test "links of a detail: outgoing first, then type, then the other task", ctx do
      %{alice: alice, keel: keel, web: [w1, _]} = ctx
      set_status!(w1, :done)
      {:ok, _} = Links.add(alice, "BOS-4", "BOS-1", "replaces")
      {:ok, _} = Links.add(alice, "BOS-1", "WEB-1", "replaces")
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      {:ok, _} = Links.add(alice, "BOS-1", "BOS-3", "depends_on")
      {:ok, _} = Links.add(keel, "BOS-1", "BOS-2", "depends_on")

      {:ok, task} = Tasks.get(alice, "BOS-1")

      assert [
               {"out", "depends_on", "BOS-2"},
               {"out", "depends_on", "BOS-3"},
               {"out", "replaces", "WEB-1"},
               {"in", "depends_on", "WEB-2"},
               {"in", "replaces", "BOS-4"}
             ] = Enum.map(task.links, &{&1.direction, &1.type, &1.task})

      [first | _] = task.links
      assert first.title == Enum.at(ctx.bos, 1).title
      assert first.status == "new"
      assert first.actor == %{name: "keel/dev", kind: "agent"}
      assert %DateTime{} = first.created_at
      assert Enum.at(task.links, 2).status == "done"
      assert Tasks.detail(task).links == task.links
    end

    test "adding and removing notify both ends and the from project", ctx do
      %{alice: alice, bos: [b1 | _], web: [_, w2]} = ctx
      subscribe_task(w2)
      subscribe_task(b1)
      subscribe_project(w2)
      subscribe_project(b1)

      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      assert_receive {:links_changed, "WEB-2"}
      assert_receive {:links_changed, "BOS-1"}
      assert_receive {:task_updated, %{id: "WEB-2", blocked: true}}
      refute_receive {:task_updated, %{id: "BOS-1"}}

      {:ok, _} = Links.remove(alice, "WEB-2", "BOS-1", "depends_on")
      assert_receive {:links_changed, "WEB-2"}
      assert_receive {:links_changed, "BOS-1"}
      assert_receive {:task_updated, %{id: "WEB-2", blocked: false}}
    end

    test "no change, no notification", ctx do
      %{alice: alice, viewer: viewer, bos: [b1 | _], web: [_, w2]} = ctx
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      subscribe_task(w2)
      subscribe_task(b1)
      subscribe_project(w2)

      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      {:ok, _} = Links.remove(alice, "WEB-2", "BOS-1", "replaces")
      {:error, {:cycle, _}} = Links.add(alice, "BOS-1", "WEB-2", "depends_on")
      {:error, :forbidden} = Links.add(viewer, "WEB-1", "BOS-1", "depends_on")

      refute_receive {:links_changed, _}
      refute_receive {:task_updated, _}
    end

    test "a prerequisite done notifies its dependents", ctx do
      %{alice: alice, web: [_, w2]} = ctx
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      {:ok, _} = Tasks.transition(alice, "BOS-1", "in_progress")
      subscribe_task(w2)
      subscribe_project(w2)

      {:ok, _} = Tasks.transition(alice, "BOS-1", "done")
      assert_receive {:task_updated, %{id: "WEB-2", blocked: false}}
      assert_receive {:links_changed, "WEB-2"}

      # Reopened: blocked again.
      {:ok, _} = Tasks.transition(alice, "BOS-1", "in_progress")
      assert_receive {:task_updated, %{id: "WEB-2", blocked: true}}
      assert_receive {:links_changed, "WEB-2"}
    end

    test "a status change that does not flip satisfied notifies no dependent", ctx do
      %{alice: alice, web: [_, w2]} = ctx
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      subscribe_task(w2)
      subscribe_project(w2)

      {:ok, _} = Tasks.transition(alice, "BOS-1", "in_progress")
      {:ok, _} = Tasks.transition(alice, "BOS-1", "cancelled")

      refute_receive {:task_updated, _}
      refute_receive {:links_changed, _}
    end

    test "a replacement also sends the replaced task's transition", ctx do
      %{alice: alice, bos: [_, b2 | _]} = ctx
      subscribe_task(b2)
      subscribe_project(b2)

      {:ok, _} = Links.add(alice, "BOS-4", "BOS-2", "replaces")

      assert_receive {:task_transitioned,
                      %{ident: "BOS-2", event: %{from: "new", to: "cancelled", auto: true}}}

      assert_receive {:task_updated, %{id: "BOS-2", status: "cancelled"}}
      assert_receive {:links_changed, "BOS-2"}
      assert_receive {:task_updated, %{id: "BOS-4"}}
    end
  end

  test "a dependent's notification starts no run and writes nothing" do
    ctx = dispatch_fixture()
    [prereq, task] = for _ <- 1..2, do: task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Links.add(ctx.alice_scope, task.ident, prereq.ident, "depends_on")
    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/dev", start: false})
    before = Repo.reload!(task)
    subscribe_task(task)

    {:ok, _} = Tasks.transition(ctx.alice_scope, prereq.ident, "in_progress")
    {:ok, _} = Tasks.transition(ctx.alice_scope, prereq.ident, "done")

    assert_receive {:links_changed, _}
    assert runs_of(task.id) == []
    assert Repo.reload!(task) == before
  end
end
