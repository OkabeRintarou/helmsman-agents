defmodule HelmsmanMCP.Tools.LinkToolsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.LinksFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanMCP.ToolHelpers

  alias Helmsman.Tasks
  alias HelmsmanMCP.{Pipeline, Tools}
  alias HelmsmanMCP.Tools.{LinkTasks, UnlinkTasks}

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)
    project_fixture(owner_scope, key: "BOS")
    project_fixture(owner_scope, key: "WEB")
    for _ <- 1..5, do: task_fixture(owner_scope, "BOS")
    for _ <- 1..2, do: task_fixture(owner_scope, "WEB")

    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    session = mcp_session(alice, workspace)
    call!(session, "identify", %{name: "keel/dev"})

    %{workspace: workspace, owner_scope: owner_scope, session: session}
  end

  defp link(session, from, to, type),
    do: call(session, "link_tasks", %{from: from, to: to, type: type})

  test "tools/list has both tools, with the direction of each type" do
    names = Enum.map(Tools.all(), & &1.name())
    assert "link_tasks" in names and "unlink_tasks" in names

    assert LinkTasks.description() =~ "type depends_on: from waits for to"
    assert LinkTasks.description() =~ "type replaces: from takes over to"
    assert UnlinkTasks.description() =~ "depends_on (from waits for to)"
    assert UnlinkTasks.description() =~ "replaces (from took over to)"

    for tool <- [LinkTasks, UnlinkTasks] do
      assert %{from: {:required, :string, _}, to: {:required, :string, _}} = tool.input_schema()
      assert tool.mode() == :write
    end
  end

  test "a dependency: the detail of from, with links and blocked", %{session: session} do
    assert {:ok, detail} = link(session, "web-2", "BOS-1", "depends-on")

    assert %{"id" => "WEB-2", "blocked" => true, "links" => [link]} = detail

    assert %{
             "type" => "depends_on",
             "direction" => "out",
             "task" => "BOS-1",
             "status" => "NEW",
             "actor" => %{"name" => "keel/dev", "kind" => "agent"},
             "created_at" => "20" <> _
           } = link

    assert %{"links" => [%{"direction" => "in", "task" => "WEB-2"}], "blocked" => false} =
             call!(session, "get_task", %{task_id: "BOS-1"})

    assert [%{"id" => "WEB-2", "blocked" => true} | _] =
             call!(session, "list_tasks", %{project_key: "WEB"})
  end

  test "unlink_tasks", %{session: session} do
    {:ok, _} = link(session, "WEB-2", "BOS-1", "depends_on")

    assert {:ok, %{"id" => "WEB-2", "links" => [], "blocked" => false}} =
             call(session, "unlink_tasks", %{from: "WEB-2", to: "BOS-1", type: "depends_on"})

    assert {:ok, %{"links" => []}} =
             call(session, "unlink_tasks", %{from: "WEB-2", to: "BOS-1", type: "depends_on"})
  end

  test "a replacement cancels the open task", %{session: session} do
    assert {:ok,
            %{"links" => [%{"type" => "replaces", "task" => "BOS-2", "status" => "CANCELLED"}]}} =
             link(session, "BOS-5", "BOS-2", "replaces")
  end

  describe "error texts" do
    test "a cycle", %{session: session} do
      {:ok, _} = link(session, "BOS-2", "BOS-3", "depends_on")
      {:ok, _} = link(session, "BOS-3", "BOS-1", "depends_on")

      assert link(session, "BOS-1", "BOS-2", "depends_on") ==
               {:error,
                "Cannot make BOS-1 depend on BOS-2: it would create the cycle " <>
                  "BOS-1 → BOS-2 → BOS-3 → BOS-1."}
    end

    test "blocked", %{session: session, owner_scope: owner_scope} do
      {:ok, _} = Tasks.transition(owner_scope, "BOS-1", "in_progress")
      {:ok, _} = link(session, "WEB-2", "BOS-1", "depends_on")

      assert call(session, "transition_task", %{task_id: "web-2", to: "in progress"}) ==
               {:error,
                "WEB-2 is blocked by BOS-1 (not finished yet). Finish them first, " <>
                  "or unlink_tasks if the dependency is wrong."}

      {:ok, _} = link(session, "WEB-2", "BOS-2", "depends_on")

      assert {:error, "WEB-2 is blocked by BOS-1, BOS-2 (not finished yet)." <> _} =
               call(session, "transition_task", %{task_id: "WEB-2", to: "IN_PROGRESS"})
    end

    test "not found names the missing end", %{session: session, workspace: workspace} do
      assert link(session, "BOS-1", "BOS-99", "replaces") ==
               {:error, "Task BOS-99 not found in workspace #{workspace.slug}."}

      assert link(session, "bos-98", "BOS-1", "replaces") ==
               {:error, "Task BOS-98 not found in workspace #{workspace.slug}."}
    end

    test "a self link", %{session: session} do
      assert link(session, "BOS-1", "bos-1", "depends_on") ==
               {:error, "A task cannot be linked to itself."}
    end

    test "an unknown type", %{session: session} do
      assert link(session, "BOS-1", "BOS-2", "relates") ==
               {:error, ~s(Unknown link type "relates". Use depends_on or replaces.)}
    end

    test "replaced, by one task and by several", %{session: session} do
      {:ok, _} = link(session, "BOS-5", "BOS-2", "replaces")

      assert call(session, "transition_task", %{task_id: "bos-2", to: "new"}) ==
               {:error,
                "BOS-2 was replaced by BOS-5. unlink_tasks(BOS-5, BOS-2, replaces) first " <>
                  "if it really needs to come back."}

      {:ok, _} = link(session, "BOS-4", "BOS-2", "replaces")

      assert call(session, "transition_task", %{task_id: "BOS-2", to: "new"}) ==
               {:error,
                "BOS-2 was replaced by BOS-4, BOS-5. Remove each link with " <>
                  "unlink_tasks(<replacer>, BOS-2, replaces) first if it really needs to " <>
                  "come back."}
    end

    test "a viewer", %{workspace: workspace} do
      viewer = user_fixture()
      member_fixture(workspace, viewer, :viewer)
      scope = %{workspace_scope_fixture(viewer, workspace) | via: :mcp}
      args = %{"from" => "BOS-1", "to" => "BOS-2", "type" => "depends_on"}

      assert Pipeline.call_module(LinkTasks, args, scope, nil) ==
               {:error, "Your role (viewer) cannot do this."}
    end
  end

  describe "in a run" do
    setup do
      ctx = dispatch_fixture()
      [own, other, third] = for _ <- 1..3, do: task_fixture(ctx.alice_scope, ctx.project.key)

      run =
        run_fixture(ctx.agent, %{
          task_id: own.id,
          status: :running,
          capabilities: ["read", "write_task"]
        })

      {scope, _token} = run_scope_fixture(run)
      %{run_scope: scope, own: own, other: other, third: third}
    end

    defp run_call(scope, tool, args), do: Pipeline.call_module(tool, args, scope, nil)

    test "replacing another open task", %{run_scope: scope, own: own, other: other} do
      args = %{"from" => own.ident, "to" => other.ident, "type" => "replaces"}

      assert run_call(scope, LinkTasks, args) ==
               {:error,
                "This run cannot replace #{other.ident}: it would cancel a task other than " <>
                  "#{own.ident}. Ask a person to do it."}

      assert status_of(other) == :new
    end

    test "a link without its own task", %{run_scope: scope, other: other, third: third} do
      args = %{"from" => other.ident, "to" => third.ident, "type" => "depends_on"}

      assert {:error, "This run can only read the workspace and change " <> _} =
               run_call(scope, LinkTasks, args)
    end
  end
end
