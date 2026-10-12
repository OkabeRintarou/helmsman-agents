defmodule HelmsmanMCP.Tools.ProjectToolsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanMCP.ToolHelpers

  alias Helmsman.{Events, Projects}
  alias Helmsman.Projects.Project
  alias HelmsmanMCP.Context
  alias HelmsmanMCP.Tools.{GetProject, ListProjects}

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)
    project_fixture(owner_scope, key: "BOS", name: "Bosun")
    project_fixture(owner_scope, key: "KEEL", name: "Keel", description: "Old")
    {:ok, _} = Projects.archive(owner_scope, project_fixture(owner_scope, key: "OLD").key)

    admin = user_fixture()
    member_fixture(workspace, admin, :admin)
    member = user_fixture()
    member_fixture(workspace, member, :member)

    %{
      workspace: workspace,
      owner_scope: owner_scope,
      admin: mcp_session(admin, workspace),
      member: mcp_session(member, workspace)
    }
  end

  defp read_ctx(%{scope: scope}, tool, args),
    do: %Context{tool: tool, args: args, scope: scope}

  defp project(scope, key) do
    {:ok, project} = Projects.get(scope, key)
    project
  end

  describe "list_projects and get_project" do
    test "list without archived projects by default", %{member: member} do
      assert {:ok, projects} = ListProjects.call(%{}, read_ctx(member, "list_projects", %{}))
      assert Enum.map(projects, & &1.key) == ["BOS", "KEEL"]

      assert %{key: "BOS", name: "Bosun", archived: false, task_count: 0} = hd(projects)
    end

    test "include_archived: true", %{member: member} do
      args = %{"include_archived" => true}
      assert {:ok, projects} = ListProjects.call(args, read_ctx(member, "list_projects", args))

      assert Enum.map(projects, &{&1.key, &1.archived}) ==
               [{"BOS", false}, {"KEEL", false}, {"OLD", true}]
    end

    test "get_project in any case", %{member: member} do
      args = %{"key" => "bos"}

      assert {:ok, %{key: "BOS", name: "Bosun"}} =
               GetProject.call(args, read_ctx(member, "get_project", args))
    end

    test "an unknown key", %{member: member, workspace: ws} do
      assert call(member, "get_project", %{key: "xx"}) ==
               {:error, "Project XX not found in workspace #{ws.slug}."}
    end
  end

  describe "create_project" do
    test "a member cannot", %{member: member, owner_scope: owner_scope} do
      assert {:error, text} = call(member, "create_project", %{key: "NEW", name: "New"})
      assert text =~ "Your role (member) cannot do this."
      assert Projects.get(owner_scope, "NEW") == {:error, :not_found}
    end

    test "an admin can", %{admin: admin} do
      assert %{"key" => "NEW", "name" => "New", "description" => "D", "archived" => false} =
               call!(admin, "create_project", %{key: "new", name: "New", description: "D"})
    end

    test "a taken key", %{admin: admin} do
      assert {:error, text} = call(admin, "create_project", %{key: "BOS", name: "x"})
      assert text == "key: has already been taken"
    end
  end

  describe "update_project" do
    test "rename and archive", %{admin: admin, owner_scope: owner_scope} do
      assert %{"key" => "KEEL", "name" => "Keel v2", "archived" => true} =
               call!(admin, "update_project", %{key: "keel", name: "Keel v2", archived: true})

      assert %Project{name: "Keel v2", description: "Old", archived_at: %DateTime{}} =
               project(owner_scope, "KEEL")
    end

    test "only archived: false restores", %{admin: admin, owner_scope: owner_scope} do
      assert %{"key" => "OLD", "archived" => false} =
               call!(admin, "update_project", %{key: "OLD", archived: false})

      assert %Project{archived_at: nil} = project(owner_scope, "OLD")
    end

    test "only fields", %{admin: admin} do
      assert %{"description" => "New", "archived" => false} =
               call!(admin, "update_project", %{key: "KEEL", description: "New"})
    end

    test "a member cannot", %{member: member, owner_scope: owner_scope} do
      assert {:error, "Your role (member) cannot do this."} =
               call(member, "update_project", %{key: "KEEL", archived: true})

      assert %Project{archived_at: nil} = project(owner_scope, "KEEL")
    end
  end

  describe "update_project is atomic (review R1)" do
    setup %{workspace: workspace} do
      Events.subscribe(Events.topic(:workspace, workspace.id))
      on_exit(fn -> Process.delete(:helmsman_test_hook) end)
    end

    test "both steps commit together, notifications after the commit",
         %{admin: admin, owner_scope: owner_scope} do
      Process.put(:helmsman_test_hook, fn :set_archived ->
        # The rename ran but has not committed: nothing was broadcast.
        refute_received {:projects_changed}
        :ok
      end)

      assert %{"name" => "Keel v2", "archived" => true} =
               call!(admin, "update_project", %{key: "KEEL", name: "Keel v2", archived: true})

      # One per step (decision 11).
      assert_received {:projects_changed}
      assert_received {:projects_changed}
      refute_received {:projects_changed}

      assert %Project{name: "Keel v2", archived_at: %DateTime{}} = project(owner_scope, "KEEL")
    end

    test "a failing second step rolls the first back", %{admin: admin, owner_scope: owner_scope} do
      before = project(owner_scope, "KEEL")
      Process.put(:helmsman_test_hook, fn :set_archived -> {:error, :forbidden} end)

      assert {:error, "Your role (admin) cannot do this."} =
               call(admin, "update_project", %{
                 key: "KEEL",
                 name: "Keel v2",
                 description: "New",
                 archived: true
               })

      assert %Project{name: "Keel", description: "Old", archived_at: nil} =
               project(owner_scope, "KEEL")

      assert project(owner_scope, "KEEL").updated_at == before.updated_at
      refute_receive {:projects_changed}
    end
  end
end
