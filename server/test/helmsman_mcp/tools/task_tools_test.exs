defmodule HelmsmanMCP.Tools.TaskToolsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanMCP.ToolHelpers

  alias Helmsman.Actors.Actor
  alias Helmsman.{Feedback, Projects, Tasks}

  @statuses "NEW, IN_PROGRESS, DONE, VERIFIED, REJECTED, CANCELLED"

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)
    project_fixture(owner_scope, key: "BOS")
    project_fixture(owner_scope, key: "KEEL")

    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    session = mcp_session(alice, workspace)
    call!(session, "identify", %{name: "keel/dev"})
    keel = Repo.get_by!(Actor, workspace_id: workspace.id, name: "keel/dev")
    agent = %{workspace_scope_fixture(alice, workspace) | actor: keel}

    %{
      workspace: workspace,
      owner_scope: owner_scope,
      alice: alice,
      session: session,
      agent: agent
    }
  end

  # BOS-1 IN_PROGRESS, KEEL-1 NEW and BOS-2 DONE, all assigned to keel/dev,
  # plus BOS-3, NEW and unassigned.
  defp my_tasks(%{agent: agent, owner_scope: owner_scope}) do
    bos1 = task_fixture(owner_scope, "BOS", assignee: "keel/dev")
    {:ok, _} = Tasks.transition(agent, bos1.ident, :in_progress)
    task_fixture(owner_scope, "KEEL", assignee: "keel/dev")
    bos2 = task_fixture(owner_scope, "BOS", assignee: "keel/dev")
    {:ok, _} = Tasks.transition(agent, bos2.ident, :in_progress)
    {:ok, _} = Tasks.transition(agent, bos2.ident, :done)
    task_fixture(owner_scope, "BOS")
    :ok
  end

  defp ids(tasks), do: Enum.map(tasks, & &1["id"])

  describe "list_tasks" do
    setup :my_tasks

    test "the given statuses, most recently updated first", %{session: session} do
      assert [
               %{"id" => "BOS-2", "status" => "DONE"},
               %{"id" => "BOS-1", "status" => "IN_PROGRESS"}
             ] =
               call!(session, "list_tasks", %{project_key: "BOS", status: ["in progress", "DONE"]})
    end

    test "status names in any spelling (decision 10)", %{session: session} do
      list = &ids(call!(session, "list_tasks", %{project_key: "BOS", status: &1}))

      assert list.("in_progress") == ["BOS-1"]
      assert list.("done") == ["BOS-2"]

      for spelling <- ["IN_PROGRESS", "in progress", "in-progress"],
          do: assert(list.(spelling) == list.("in_progress"), spelling)

      assert list.("DONE") == list.("done")
      assert list.(["in progress", "DONE"]) == list.(["in_progress", "done"])
      assert list.(["in progress", "DONE"]) == ["BOS-2", "BOS-1"]
    end

    test "an unknown status is an error, not an empty list", %{session: session} do
      for status <- ["doing", ["done", "doing"]] do
        assert call(session, "list_tasks", %{project_key: "BOS", status: status}) ==
                 {:error, ~s(Unknown status "doing". Use one of: #{@statuses}.)}
      end
    end

    test "label, assignee, limit and offset", %{session: session} do
      assert ids(call!(session, "list_tasks", %{project_key: "BOS", assignee: ""})) == ["BOS-3"]

      assert length(call!(session, "list_tasks", %{project_key: "BOS", assignee: "keel/dev"})) ==
               2

      assert ids(call!(session, "list_tasks", %{project_key: "BOS", limit: 1, offset: 1})) == [
               "BOS-2"
             ]

      assert call!(session, "list_tasks", %{project_key: "BOS", label: "nope"}) == []
    end

    test "summaries", %{session: session} do
      assert [%{"id" => "BOS-3"} = summary | _] =
               call!(session, "list_tasks", %{project_key: "BOS"})

      assert %{
               "project_key" => "BOS",
               "status" => "NEW",
               "priority" => "medium",
               "labels" => [],
               "assignee" => nil,
               "created_by" => %{"kind" => "human"},
               "commits" => [],
               "feedback_count" => 0,
               "open_question" => false,
               "lock_version" => 1
             } = summary
    end
  end

  describe "list_my_tasks" do
    setup :my_tasks

    test "NEW and IN_PROGRESS by default, across projects", %{session: session} do
      assert ids(call!(session, "list_my_tasks")) == ["KEEL-1", "BOS-1"]
    end

    test "a given status", %{session: session} do
      assert ids(call!(session, "list_my_tasks", %{status: "done"})) == ["BOS-2"]

      assert ids(call!(session, "list_my_tasks", %{status: ["DONE", "new"]})) == [
               "BOS-2",
               "KEEL-1"
             ]
    end

    test "no identity, and none is created", %{workspace: workspace, alice: alice} do
      session = mcp_session(alice, workspace)
      count = Repo.aggregate(where(Actor, workspace_id: ^workspace.id), :count)

      assert call(session, "list_my_tasks") ==
               {:error,
                "You have no identity in this session. Call identify(name, project, worktree) first."}

      assert Repo.aggregate(where(Actor, workspace_id: ^workspace.id), :count) == count
    end

    test "the token's default agent", %{workspace: workspace, alice: alice} do
      keel = Repo.get_by!(Actor, workspace_id: workspace.id, name: "keel/dev")
      session = mcp_session(alice, workspace, %{default_agent_id: keel.id})
      assert ids(call!(session, "list_my_tasks")) == ["KEEL-1", "BOS-1"]
    end
  end

  describe "create_task" do
    test "as the session identity", %{session: session} do
      assert %{
               "id" => "BOS-1",
               "title" => "Fix login",
               "status" => "NEW",
               "created_by" => %{"name" => "keel/dev", "kind" => "agent"},
               "history" => [%{"from" => nil, "to" => "NEW"}]
             } =
               call!(session, "create_task", %{
                 project_key: "bos",
                 title: "Fix login",
                 labels: ["Auth"],
                 priority: "high"
               })
    end

    test "fields", %{session: session} do
      assert %{"labels" => ["auth"], "priority" => "high", "assignee" => %{"name" => "keel/dev"}} =
               call!(session, "create_task", %{
                 project_key: "BOS",
                 title: "T",
                 labels: ["Auth"],
                 priority: "high",
                 assignee: "keel/dev"
               })
    end

    test "an archived project", %{session: session, owner_scope: owner_scope} do
      {:ok, _} = Projects.archive(owner_scope, "BOS")

      assert call(session, "create_task", %{project_key: "bos", title: "T"}) ==
               {:error,
                "Project BOS is archived and cannot take new tasks. " <>
                  "An admin can restore it with update_project(archived: false)."}
    end

    test "an unknown project and an invalid field", %{session: session, workspace: ws} do
      assert call(session, "create_task", %{project_key: "XX", title: "T"}) ==
               {:error, "Project XX not found in workspace #{ws.slug}."}

      assert {:error, "assignee: does not exist"} =
               call(session, "create_task", %{project_key: "BOS", title: "T", assignee: "nobody"})
    end
  end

  describe "update_task" do
    setup %{owner_scope: owner_scope} do
      task = task_fixture(owner_scope, "BOS", title: "Old")
      {:ok, _} = Tasks.update(owner_scope, task.ident, %{title: "Older"})
      {:ok, _} = Tasks.update(owner_scope, task.ident, %{title: "Old"})
      {:ok, _} = Tasks.update(owner_scope, task.ident, %{description: "D"})
      %{task: Repo.reload!(task)}
    end

    test "a stale lock_version", %{session: session, task: task, owner_scope: owner_scope} do
      assert task.lock_version == 4

      assert call(session, "update_task", %{task_id: "BOS-1", title: "x", lock_version: 3}) ==
               {:error,
                "BOS-1 was changed by someone else since you read it. " <>
                  "Call get_task to see the latest version (lock_version), then retry."}

      assert {:ok, %{title: "Old"}} = Tasks.get(owner_scope, "BOS-1")
    end

    test "the current lock_version", %{session: session} do
      assert %{"title" => "x", "lock_version" => 5} =
               call!(session, "update_task", %{task_id: "bos-1", title: "x", lock_version: 4})
    end

    test "without lock_version, the latest version", %{session: session} do
      assert %{"title" => "x", "description" => "D", "lock_version" => 5} =
               call!(session, "update_task", %{task_id: "BOS-1", title: "x"})
    end

    test "a status argument is ignored", %{session: session} do
      assert %{"status" => "NEW", "title" => "x"} =
               call!(session, "update_task", %{task_id: "BOS-1", title: "x", status: "DONE"})
    end
  end

  describe "get_task" do
    test "history and feedback", %{session: session, agent: agent, owner_scope: owner_scope} do
      task_fixture(owner_scope, "BOS", title: "Fix login", description: "Steps")
      {:ok, _} = Tasks.transition(agent, "BOS-1", "in progress")
      {:ok, _} = Feedback.add(agent, "BOS-1", %{kind: "question", content: "Why?"})
      {:ok, _} = Feedback.add(owner_scope, "BOS-1", %{kind: "answer", content: "Because"})

      assert %{
               "id" => "BOS-1",
               "status" => "IN_PROGRESS",
               "description" => "Steps",
               "assignee" => %{"name" => "keel/dev", "kind" => "agent"},
               "history" => [
                 %{"from" => nil, "to" => "NEW"},
                 %{"from" => "NEW", "to" => "IN_PROGRESS", "actor" => %{"name" => "keel/dev"}}
               ],
               "feedback" => [
                 %{"id" => "BOS-1#1", "kind" => "question", "content" => "Why?"},
                 %{"id" => "BOS-1#2", "kind" => "answer", "content" => "Because"}
               ]
             } = call!(session, "get_task", %{task_id: "bos-1"})
    end

    test "not found", %{session: session, workspace: ws} do
      assert call(session, "get_task", %{task_id: "BOS-99"}) ==
               {:error, "Task BOS-99 not found in workspace #{ws.slug}."}
    end
  end
end
