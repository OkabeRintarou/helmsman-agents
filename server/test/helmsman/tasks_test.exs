defmodule Helmsman.TasksTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Projects
  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)

    scopes =
      Map.new([:member, :viewer], fn role ->
        user = user_fixture()
        member_fixture(workspace, user, role)
        {role, workspace_scope_fixture(user, workspace)}
      end)

    project = project_fixture(owner_scope, key: "BOS", name: "Bosun")
    Events.subscribe(Events.topic(:project, project.id))

    Map.merge(scopes, %{workspace: workspace, owner: owner_scope, project: project})
  end

  defp agent_fixture(workspace, owner_scope, name, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Actor{
          workspace_id: workspace.id,
          kind: :agent,
          name: name,
          owner_id: owner_scope.user.id
        },
        attrs
      )
    )
  end

  defp subscribe_task(%Task{id: id}), do: Events.subscribe(Events.topic(:task, id))

  describe "create/3" do
    test "numbers tasks one after another; each starts new with a creation entry",
         %{member: member} do
      %{ident: "BOS-1"} = task_fixture(member, "BOS")
      %{ident: "BOS-2"} = task_fixture(member, "bos")

      assert {:ok, %Task{ident: "BOS-3", seq: 3, status: :new} = task} =
               Tasks.create(member, "BOS", %{title: "Third"})

      assert task.created_by.id == member.actor.id
      assert [%{from_status: nil, to_status: :new, actor_id: actor_id}] = task.events
      assert actor_id == member.actor.id
      assert {:ok, %{task_seq: 3}} = Projects.get(member, "BOS")
    end

    test "notifies the project and the task topics after the commit", %{member: member} do
      # The task topic is known once the task exists: subscribe before the
      # outer transaction commits.
      {:ok, task} =
        Tx.run(fn ->
          {:ok, task} = Tasks.create(member, "BOS", %{title: "New"})
          subscribe_task(task)
          refute_received {:task_created, _}
          {:ok, task}
        end)

      assert_receive {:task_created, %{id: "BOS-1", title: "New", status: "new"}}
      assert_receive {:task_updated, "BOS-1"}
      assert task.ident == "BOS-1"
    end

    test "viewers may not create tasks", %{viewer: viewer} do
      assert Tasks.create(viewer, "BOS", %{title: "T"}) == {:error, :forbidden}
      refute_receive {:task_created, _}
    end

    test "unknown projects are not found", %{member: member} do
      assert Tasks.create(member, "NOPE", %{title: "T"}) == {:error, :not_found}
    end

    test "archived projects return project_archived", %{member: member, owner: owner} do
      {:ok, _} = Projects.archive(owner, "BOS")
      assert Tasks.create(member, "BOS", %{title: "T"}) == {:error, :project_archived}
      assert {:ok, %{task_seq: 0}} = Projects.get(member, "BOS")
      refute_receive {:task_created, _}
    end

    test "a scope without an actor is refused", %{member: member} do
      assert Tasks.create(%{member | actor: nil}, "BOS", %{title: "T"}) == {:error, :no_actor}
    end

    test "normalizes labels", %{member: member} do
      assert {:ok, %Task{labels: ["backend", "api"]}} =
               Tasks.create(member, "BOS", %{title: "T", labels: [" Backend", "backend", "API "]})
    end

    test "cannot assign to the system identity", %{member: member} do
      assert {:error, changeset} =
               Tasks.create(member, "BOS", %{title: "T", assignee: "helmsman"})

      assert errors_on(changeset).assignee == ["cannot be the system identity"]
    end

    test "rejects a 201-character title without using a number", %{member: member} do
      assert {:error, changeset} =
               Tasks.create(member, "BOS", %{"title" => String.duplicate("t", 201)})

      assert errors_on(changeset).title == ["should be at most 200 character(s)"]
      assert {:ok, %{task_seq: 0}} = Projects.get(member, "BOS")
      refute_receive {:task_created, _}
    end

    test "assigns by name; rejects unknown and disabled identities",
         %{member: member, owner: owner, workspace: ws} do
      agent_fixture(ws, owner, "claude")
      agent_fixture(ws, owner, "retired", disabled_at: DateTime.utc_now(:second))

      assert {:ok, %Task{assignee: %Actor{name: "claude"}}} =
               Tasks.create(member, "BOS", %{title: "T", assignee: "Claude"})

      assert {:error, changeset} = Tasks.create(member, "BOS", %{title: "T", assignee: "ghost"})
      assert errors_on(changeset).assignee == ["does not exist"]

      assert {:error, changeset} =
               Tasks.create(member, "BOS", %{title: "T", assignee: "retired"})

      assert errors_on(changeset).assignee == ["is disabled"]

      assert {:ok, %Task{assignee: nil}} =
               Tasks.create(member, "BOS", %{title: "T", assignee: ""})
    end

    test "identities of another workspace cannot be assigned", %{member: member} do
      other = user_fixture()
      other_ws = workspace_fixture(other)
      agent_fixture(other_ws, workspace_scope_fixture(other, other_ws), "elsewhere")

      assert {:error, changeset} =
               Tasks.create(member, "BOS", %{title: "T", assignee: "elsewhere"})

      assert errors_on(changeset).assignee == ["does not exist"]
    end
  end

  describe "get/2" do
    setup %{member: member} do
      for _ <- 1..3, do: task_fixture(member, "BOS")
      :ok
    end

    test "reads by ID in any case", %{viewer: viewer} do
      assert {:ok, %Task{ident: "BOS-3"}} = Tasks.get(viewer, "bos-3")
    end

    test "leading zeros and malformed IDs are not found", %{viewer: viewer} do
      for ident <- ["BOS-03", "BOS-0", "BOS", "BOS-4", "NOPE-1"] do
        assert Tasks.get(viewer, ident) == {:error, :not_found}
      end
    end

    test "tasks of another workspace are not found", %{viewer: viewer} do
      other = user_fixture()
      other_scope = workspace_scope_fixture(other, workspace_fixture(other))
      project_fixture(other_scope, key: "BETA")
      task_fixture(other_scope, "BETA")

      assert Tasks.get(viewer, "BETA-1") == {:error, :not_found}
    end

    test "tasks of archived projects stay readable and editable",
         %{viewer: viewer, member: member, owner: owner} do
      {:ok, _} = Projects.archive(owner, "BOS")
      assert {:ok, %Task{ident: "BOS-1"}} = Tasks.get(viewer, "BOS-1")
      assert {:ok, %Task{title: "Edited"}} = Tasks.update(member, "BOS-1", %{title: "Edited"})
    end
  end

  describe "summary/1 and detail/1" do
    test "the external form", %{member: member, owner: owner, workspace: ws} do
      agent_fixture(ws, owner, "claude")

      {:ok, _} =
        Tasks.create(member, "BOS", %{
          title: "Fix it",
          description: "**now**",
          priority: "high",
          labels: ["api"],
          assignee: "claude"
        })

      {:ok, task} = Tasks.get(member, "BOS-1")
      member_name = member.actor.name

      assert %{
               id: "BOS-1",
               project_key: "BOS",
               title: "Fix it",
               status: "new",
               priority: "high",
               labels: ["api"],
               created_by: %{name: ^member_name, kind: "human"},
               assignee: %{name: "claude", kind: "agent"},
               lock_version: 1,
               created_at: %DateTime{},
               updated_at: %DateTime{},
               description: "**now**",
               history: [
                 %{
                   from: nil,
                   to: "new",
                   actor: %{name: ^member_name},
                   comment: nil,
                   at: %DateTime{}
                 }
               ]
             } = Tasks.detail(task)

      summary = Tasks.summary(task)
      refute Map.has_key?(summary, :description)
      refute Map.has_key?(summary, :history)
      assert %{assignee: %{name: "claude"}} = summary
    end

    test "unassigned tasks have a nil assignee", %{member: member} do
      task = task_fixture(member, "BOS")
      assert %{assignee: nil} = Tasks.summary(task)
    end
  end

  describe "list/3" do
    setup %{member: member, owner: owner, workspace: ws} do
      agent_fixture(ws, owner, "claude")

      tasks =
        for {title, labels, assignee} <- [
              {"one", ["backend"], "claude"},
              {"two", ["frontend"], nil},
              {"three", ["backend", "api"], nil}
            ] do
          task_fixture(member, "BOS", title: title, labels: labels, assignee: assignee)
        end

      # Statuses only change through the state machine: set one directly.
      Repo.update_all(from(t in Task, where: t.ident == "BOS-2"), set: [status: :in_progress])
      Repo.update_all(from(t in Task, where: t.ident == "BOS-3"), set: [status: :done])
      %{tasks: tasks}
    end

    defp idents({:ok, tasks}), do: Enum.map(tasks, & &1.ident)

    test "most recently updated first", %{viewer: viewer, member: member} do
      assert idents(Tasks.list(viewer, "BOS")) == ["BOS-3", "BOS-2", "BOS-1"]
      {:ok, _} = Tasks.update(member, "BOS-1", %{title: "touched"})
      assert idents(Tasks.list(viewer, "bos")) == ["BOS-1", "BOS-3", "BOS-2"]
    end

    test "filters by status and label together", %{viewer: viewer, member: member} do
      task_fixture(member, "BOS", title: "four", labels: ["Backend"])

      assert idents(Tasks.list(viewer, "BOS", status: ["new", "in_progress"], label: "backend")) ==
               ["BOS-4", "BOS-1"]

      assert idents(Tasks.list(viewer, "BOS", status: :done)) == ["BOS-3"]
      assert idents(Tasks.list(viewer, "BOS", status: "bogus")) == []
      assert idents(Tasks.list(viewer, "BOS", label: "API")) == ["BOS-3"]
    end

    test "filters by assignee name; empty means unassigned", %{viewer: viewer} do
      assert idents(Tasks.list(viewer, "BOS", assignee: "claude")) == ["BOS-1"]
      assert idents(Tasks.list(viewer, "BOS", assignee: "")) == ["BOS-3", "BOS-2"]
      assert idents(Tasks.list(viewer, "BOS", assignee: "ghost")) == []
    end

    test "limit and offset; limit is capped at 200", %{viewer: viewer, member: member} do
      assert idents(Tasks.list(viewer, "BOS", limit: 2)) == ["BOS-3", "BOS-2"]
      assert idents(Tasks.list(viewer, "BOS", limit: 2, offset: 2)) == ["BOS-1"]

      for i <- 4..205, do: task_fixture(member, "BOS", title: "t#{i}")
      assert {:ok, tasks} = Tasks.list(viewer, "BOS", limit: 1000)
      assert length(tasks) == 200
      assert {:ok, tasks} = Tasks.list(viewer, "BOS")
      assert length(tasks) == 50
    end

    test "unknown projects are not found", %{viewer: viewer} do
      assert Tasks.list(viewer, "NOPE") == {:error, :not_found}
    end

    defp cursor(%Task{updated_at: updated_at, id: id}), do: {updated_at, id}

    test "before: the page after a cursor, offset ignored", %{viewer: viewer} do
      {:ok, [_, second]} = Tasks.list(viewer, "BOS", limit: 2)
      assert second.ident == "BOS-2"

      assert idents(Tasks.list(viewer, "BOS", before: cursor(second))) == ["BOS-1"]
      assert idents(Tasks.list(viewer, "BOS", before: cursor(second), offset: 5)) == ["BOS-1"]
      assert idents(Tasks.list(viewer, "BOS", before: nil, offset: 1)) == ["BOS-2", "BOS-1"]

      {:ok, [last]} = Tasks.list(viewer, "BOS", before: cursor(second))
      assert idents(Tasks.list(viewer, "BOS", before: cursor(last))) == []
    end

    test "before: equal update times are ordered by id", %{viewer: viewer} do
      at = ~U[2026-01-01 00:00:00.000000Z]
      Repo.update_all(Task, set: [updated_at: at])

      assert idents(Tasks.list(viewer, "BOS")) == ["BOS-3", "BOS-2", "BOS-1"]
      {:ok, [_, second]} = Tasks.list(viewer, "BOS", limit: 2)

      assert idents(Tasks.list(viewer, "BOS", before: cursor(second), limit: 2)) == ["BOS-1"]
    end

    test "before: with filters", %{viewer: viewer} do
      {:ok, [first | _]} = Tasks.list(viewer, "BOS")

      assert idents(Tasks.list(viewer, "BOS", label: "backend", before: cursor(first))) == [
               "BOS-1"
             ]
    end
  end

  describe "list_labels/2" do
    test "distinct labels of the project, sorted", %{viewer: viewer, member: member, owner: owner} do
      task_fixture(member, "BOS", labels: ["backend", "api"])
      task_fixture(member, "BOS", labels: ["Backend", "ui"])
      task_fixture(member, "BOS")
      project_fixture(owner, key: "OTH")
      task_fixture(member, "OTH", labels: ["other"])

      assert Tasks.list_labels(viewer, "bos") == {:ok, ["api", "backend", "ui"]}
      assert Tasks.list_labels(viewer, "OTH") == {:ok, ["other"]}
    end

    test "no labels, unknown projects, other workspaces", %{viewer: viewer} do
      assert Tasks.list_labels(viewer, "BOS") == {:ok, []}
      assert Tasks.list_labels(viewer, "NOPE") == {:error, :not_found}

      other = user_fixture()
      other_scope = workspace_scope_fixture(other, workspace_fixture(other))
      assert Tasks.list_labels(other_scope, "BOS") == {:error, :not_found}
    end

    test "scopes without a role are refused", %{viewer: viewer} do
      assert Tasks.list_labels(%{viewer | role: nil}, "BOS") == {:error, :forbidden}
    end
  end

  describe "update/4" do
    setup %{member: member} do
      task = task_fixture(member, "BOS", title: "Original", labels: ["api"])
      assert_receive {:task_created, _}
      subscribe_task(task)
      %{task: task}
    end

    test "with a stale version: stale, nothing changes, no notification",
         %{member: member, owner: owner} do
      # alice and bob both opened version 1; bob saves first.
      assert {:ok, %Task{lock_version: 2}} = Tasks.update(owner, "BOS-1", %{title: "Bob"}, 1)
      assert_receive {:task_updated, %{title: "Bob"}}
      assert_receive {:task_updated, "BOS-1"}

      assert Tasks.update(member, "BOS-1", %{title: "Alice"}, 1) == {:error, :stale}
      assert {:ok, %Task{title: "Bob", lock_version: 2}} = Tasks.get(member, "BOS-1")
      refute_receive {:task_updated, _}
    end

    test "without a version the latest wins and the version grows", %{member: member} do
      assert {:ok, %Task{labels: ["backend"], lock_version: 2}} =
               Tasks.update(member, "BOS-1", %{"labels" => ["Backend"]})

      assert_receive {:task_updated, %{id: "BOS-1", labels: ["backend"], lock_version: 2}}
      assert_receive {:task_updated, "BOS-1"}
    end

    test "status in the request is ignored", %{member: member} do
      assert {:ok, %Task{status: :new, title: "New title", lock_version: 2}} =
               Tasks.update(member, "BOS-1", %{status: "done", title: "New title"}, 1)
    end

    test "no actual change: ok, same version and time, no notification",
         %{member: member, task: task} do
      assert {:ok, %Task{lock_version: 1, updated_at: updated_at}} =
               Tasks.update(member, "BOS-1", %{title: " Original ", labels: ["API"]}, 1)

      assert updated_at == task.updated_at
      assert {:ok, %Task{lock_version: 1}} = Tasks.update(member, "BOS-1", %{status: "done"}, 1)
      assert {:ok, %Task{lock_version: 1}} = Tasks.update(member, "BOS-1", %{assignee: nil})
      refute_receive {:task_updated, _}
    end

    test "no change but a stale version is still stale", %{member: member} do
      {:ok, _} = Tasks.update(member, "BOS-1", %{title: "Changed"})
      assert Tasks.update(member, "BOS-1", %{title: "Changed"}, 1) == {:error, :stale}
    end

    test "changes priority, description and assignee", %{
      member: member,
      owner: owner,
      workspace: ws
    } do
      agent_fixture(ws, owner, "claude")

      assert {:ok, %Task{priority: :low, description: "d", assignee: %Actor{name: "claude"}}} =
               Tasks.update(member, "bos-1", %{
                 priority: "low",
                 description: "d",
                 assignee: "claude"
               })

      assert {:ok, %Task{assignee: nil, lock_version: 3}} =
               Tasks.update(member, "BOS-1", %{"assignee" => ""})
    end

    test "unknown or system assignees fail and change nothing", %{member: member} do
      assert {:error, changeset} = Tasks.update(member, "BOS-1", %{title: "X", assignee: "ghost"})
      assert errors_on(changeset).assignee == ["does not exist"]

      assert {:error, changeset} = Tasks.update(member, "BOS-1", %{assignee: "helmsman"})
      assert errors_on(changeset).assignee == ["cannot be the system identity"]

      assert {:ok, %Task{title: "Original", lock_version: 1}} = Tasks.get(member, "BOS-1")
      refute_receive {:task_updated, _}
    end

    test "invalid fields fail", %{member: member} do
      assert {:error, changeset} = Tasks.update(member, "BOS-1", %{title: ""})
      assert errors_on(changeset).title
      refute_receive {:task_updated, _}
    end

    test "viewers may not edit; unknown IDs are not found", %{viewer: viewer, member: member} do
      assert Tasks.update(viewer, "BOS-1", %{title: "X"}) == {:error, :forbidden}
      assert Tasks.update(member, "BOS-9", %{title: "X"}) == {:error, :not_found}
      assert Tasks.update(member, "BOS-01", %{title: "X"}) == {:error, :not_found}
    end
  end
end
