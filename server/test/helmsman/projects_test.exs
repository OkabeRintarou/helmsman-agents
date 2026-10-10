defmodule Helmsman.ProjectsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Events
  alias Helmsman.Projects
  alias Helmsman.Projects.Project

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)

    scopes =
      Map.new([:admin, :member, :viewer], fn role ->
        user = user_fixture()
        member_fixture(workspace, user, role)
        {role, workspace_scope_fixture(user, workspace)}
      end)

    Events.subscribe(Events.topic(:workspace, workspace.id))

    %{workspace: workspace, owner: workspace_scope_fixture(owner, workspace)}
    |> Map.merge(scopes)
  end

  describe "create/2" do
    test "admin creates a project; the key is upcased", %{admin: admin} do
      assert {:ok, %Project{key: "BOS", name: "Bosun", task_seq: 0, archived_at: nil}} =
               Projects.create(admin, %{key: "bos", name: "Bosun"})

      assert_receive {:projects_changed}
    end

    test "invalid keys fail with the key rule", %{admin: admin} do
      for key <- ["1BOS", "B", "BOS-X", "ABCDEFGHIJK"] do
        assert {:error, changeset} = Projects.create(admin, %{key: key, name: "X"})
        assert ["must be 2-10 characters" <> _] = errors_on(changeset).key
      end

      refute_receive {:projects_changed}
    end

    test "a key already taken in the workspace, in any case", %{admin: admin, owner: owner} do
      project_fixture(owner, key: "BOS")
      assert_receive {:projects_changed}

      assert {:error, changeset} = Projects.create(admin, %{key: "Bos", name: "X"})
      assert errors_on(changeset).key == ["has already been taken"]
      refute_receive {:projects_changed}
    end

    test "the same key in another workspace is fine", %{admin: admin} do
      other = user_fixture()
      other_scope = workspace_scope_fixture(other, workspace_fixture(other))
      project_fixture(other_scope, key: "BOS")

      assert {:ok, _} = Projects.create(admin, %{key: "BOS", name: "X"})
    end

    test "members and viewers may not create projects", %{member: member, viewer: viewer} do
      for scope <- [member, viewer] do
        assert Projects.create(scope, %{key: "BOS", name: "X"}) == {:error, :forbidden}
      end

      refute_receive {:projects_changed}
    end
  end

  describe "get/2 and list/2" do
    setup %{owner: owner} do
      project_fixture(owner, key: "BOS", name: "Bosun")
      project_fixture(owner, key: "OLD", name: "Old")
      {:ok, _} = Projects.archive(owner, "OLD")
      :ok
    end

    test "viewers read a project by key in any case", %{viewer: viewer} do
      assert {:ok, %Project{key: "BOS"}} = Projects.get(viewer, "bos")
      assert {:ok, %Project{key: "OLD"}} = Projects.get(viewer, "Old")
      assert Projects.get(viewer, "NOPE") == {:error, :not_found}
      assert Projects.get(viewer, "BOS-1") == {:error, :not_found}
    end

    test "projects of another workspace are not found", %{viewer: viewer} do
      other = user_fixture()
      other_scope = workspace_scope_fixture(other, workspace_fixture(other))
      project_fixture(other_scope, key: "ELSE")

      assert Projects.get(viewer, "ELSE") == {:error, :not_found}
      assert {:ok, projects} = Projects.list(viewer, include_archived: true)
      refute "ELSE" in Enum.map(projects, & &1.key)
    end

    test "the default list leaves out archived projects", %{viewer: viewer} do
      assert {:ok, [%Project{key: "BOS"}]} = Projects.list(viewer)
      assert {:ok, projects} = Projects.list(viewer, include_archived: true)
      assert Enum.map(projects, & &1.key) == ["BOS", "OLD"]
    end

    test "the task count is task_seq", %{viewer: viewer, member: member} do
      task_fixture(member, "BOS")
      task_fixture(member, "BOS")

      assert {:ok, [%Project{key: "BOS", task_seq: 2}]} = Projects.list(viewer)
      assert {:ok, %Project{task_seq: 2}} = Projects.get(viewer, "BOS")
    end
  end

  describe "update/3" do
    setup %{owner: owner} do
      project_fixture(owner, key: "BOS", name: "Bosun")
      assert_receive {:projects_changed}
      :ok
    end

    test "changes name and description; the key stays", %{admin: admin} do
      assert {:ok, %Project{key: "BOS", name: "Helm", description: "About"}} =
               Projects.update(admin, "bos", %{key: "NEW", name: " Helm ", description: "About"})

      assert_receive {:projects_changed}
      assert Projects.get(admin, "NEW") == {:error, :not_found}
    end

    test "invalid input changes nothing and notifies nobody", %{admin: admin} do
      assert {:error, changeset} = Projects.update(admin, "BOS", %{name: ""})
      assert errors_on(changeset).name
      refute_receive {:projects_changed}
      assert {:ok, %Project{name: "Bosun"}} = Projects.get(admin, "BOS")
    end

    test "no change, no notification", %{admin: admin} do
      assert {:ok, %Project{name: "Bosun"}} = Projects.update(admin, "BOS", %{name: "Bosun"})
      refute_receive {:projects_changed}
    end

    test "members may not update; unknown keys are not found", %{member: member, admin: admin} do
      assert Projects.update(member, "BOS", %{name: "X"}) == {:error, :forbidden}
      assert Projects.update(admin, "NOPE", %{name: "X"}) == {:error, :not_found}
      refute_receive {:projects_changed}
    end
  end

  describe "archive/2 and unarchive/2" do
    setup %{owner: owner} do
      project_fixture(owner, key: "BOS")
      assert_receive {:projects_changed}
      :ok
    end

    test "archived projects take no tasks; restored ones continue numbering",
         %{admin: admin, member: member} do
      %{ident: "BOS-1"} = task_fixture(member, "BOS")
      %{ident: "BOS-2"} = task_fixture(member, "BOS")

      assert {:ok, %Project{archived_at: %DateTime{}}} = Projects.archive(admin, "BOS")
      assert_receive {:projects_changed}

      assert Helmsman.Tasks.create(member, "BOS", %{title: "T"}) ==
               {:error, :project_archived}

      assert {:ok, %Project{task_seq: 2}} = Projects.get(admin, "BOS")

      assert {:ok, %Project{archived_at: nil}} = Projects.unarchive(admin, "bos")
      assert_receive {:projects_changed}
      assert {:ok, [%Project{key: "BOS"}]} = Projects.list(admin)
      assert %{ident: "BOS-3"} = task_fixture(member, "BOS")
    end

    test "archiving twice keeps the first time and notifies once", %{admin: admin} do
      {:ok, %Project{archived_at: archived_at}} = Projects.archive(admin, "BOS")
      assert_receive {:projects_changed}

      assert {:ok, %Project{archived_at: ^archived_at}} = Projects.archive(admin, "BOS")
      refute_receive {:projects_changed}
    end

    test "members may not archive or restore", %{member: member} do
      assert Projects.archive(member, "BOS") == {:error, :forbidden}
      assert Projects.unarchive(member, "BOS") == {:error, :forbidden}
    end

    test "an admin's agent may create and archive projects", %{admin: admin, workspace: ws} do
      agent =
        Repo.insert!(%Helmsman.Actors.Actor{
          workspace_id: ws.id,
          kind: :agent,
          name: "claude",
          owner_id: admin.user.id
        })

      agent_scope = %{admin | actor: agent, via: :mcp}
      assert {:ok, %Project{key: "AGT"}} = Projects.create(agent_scope, %{key: "agt", name: "A"})
      assert {:ok, %Project{}} = Projects.archive(agent_scope, "AGT")
    end
  end
end
