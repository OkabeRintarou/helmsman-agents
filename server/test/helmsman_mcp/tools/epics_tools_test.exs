defmodule HelmsmanMCP.Tools.EpicsToolsTest do
  # `add-epics` decision 10: the epic arguments and output of the task tools.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanMCP.ToolHelpers

  alias Helmsman.Tasks
  alias HelmsmanMCP.Tools

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)
    project_fixture(owner_scope, key: "BOS")
    project_fixture(owner_scope, key: "WEB")
    session = mcp_session(owner, workspace)
    call!(session, "identify", %{name: "keel/dev"})
    %{session: session, owner_scope: owner_scope}
  end

  defp create!(session, args), do: call!(session, "create_task", args)

  test "the input schemas describe the new arguments" do
    for {name, args} <- [
          {"create_task", [:kind, :epic]},
          {"update_task", [:epic]},
          {"list_tasks", [:kind, :epic]}
        ],
        arg <- args do
      {:ok, tool} = Tools.fetch(name)
      assert {:string, opts} = Map.fetch!(tool.input_schema(), arg), "#{name} #{arg}"
      assert opts[:description] =~ ~r/\A[\x20-\x7e]+\z/
    end
  end

  test "an epic and a step under it", %{session: session} do
    epic = create!(session, %{"project_key" => "BOS", "title" => "Revamp", "kind" => "epic"})
    assert %{"id" => "BOS-1", "kind" => "epic", "epic" => nil, "children" => []} = epic
    assert %{"total" => 0, "done" => 0, "by_status" => %{"NEW" => 0}} = epic["progress"]

    step =
      create!(session, %{"project_key" => "WEB", "title" => "Login form", "epic" => "bos-1"})

    assert %{"epic" => "BOS-1", "kind" => "task", "progress" => nil} = step
    assert %{"epic_title" => "Revamp", "children" => nil} = step
  end

  test "get_task of an epic with two steps", %{session: session} do
    create!(session, %{"project_key" => "BOS", "title" => "Revamp", "kind" => "epic"})
    create!(session, %{"project_key" => "WEB", "title" => "A", "epic" => "BOS-1"})
    create!(session, %{"project_key" => "BOS", "title" => "B", "epic" => "BOS-1"})
    call!(session, "transition_task", %{"task_id" => "BOS-2", "to" => "in_progress"})

    epic = call!(session, "get_task", %{"task_id" => "BOS-1"})

    assert %{"kind" => "epic", "progress" => %{"total" => 2, "done" => 0}} = epic

    assert %{"IN_PROGRESS" => 1, "NEW" => 1, "DONE" => 0, "VERIFIED" => 0} =
             epic["progress"]["by_status"]

    assert [
             %{"id" => "WEB-1", "status" => "NEW", "epic" => "BOS-1"},
             %{"id" => "BOS-2", "status" => "IN_PROGRESS"}
           ] = epic["children"]

    refute inspect(epic) =~ ~r/"epic_id"|"project_id"|"workspace_id"/
  end

  test "update_task: the target is not an epic", %{session: session, owner_scope: scope} do
    task_fixture(scope, "BOS")
    task_fixture(scope, "BOS")
    task_fixture(scope, "BOS")
    task_fixture(scope, "BOS")

    assert {:error, text} =
             call(session, "update_task", %{"task_id" => "BOS-3", "epic" => "BOS-4"})

    assert text =~ "epic: is not an epic"
    assert {:ok, %{epic_id: nil}} = Tasks.get(scope, "BOS-3")
  end

  test "update_task attaches and detaches", %{session: session, owner_scope: scope} do
    task_fixture(scope, "BOS", kind: "epic")
    task_fixture(scope, "WEB")

    assert %{"epic" => "BOS-1", "lock_version" => 2} =
             call!(session, "update_task", %{"task_id" => "WEB-1", "epic" => "BOS-1"})

    assert %{"epic" => nil, "lock_version" => 3} =
             call!(session, "update_task", %{"task_id" => "WEB-1", "epic" => ""})
  end

  test "create_task: field errors", %{session: session} do
    assert {:error, "kind: is invalid"} =
             call(session, "create_task", %{"project_key" => "BOS", "title" => "T", "kind" => "x"})

    assert {:error, "epic: not found"} =
             call(session, "create_task", %{
               "project_key" => "BOS",
               "title" => "T",
               "epic" => "X-9"
             })
  end

  test "list_tasks by kind and epic", %{session: session, owner_scope: scope} do
    task_fixture(scope, "BOS", kind: "epic")
    task_fixture(scope, "BOS", epic: "BOS-1")
    task_fixture(scope, "BOS")

    ids = fn args ->
      session |> call!("list_tasks", Map.put(args, "project_key", "BOS")) |> Enum.map(& &1["id"])
    end

    assert ids.(%{"kind" => "epic"}) == ["BOS-1"]
    assert Enum.sort(ids.(%{"kind" => "task"})) == ["BOS-2", "BOS-3"]
    assert ids.(%{"epic" => "BOS-1"}) == ["BOS-2"]
    assert Enum.sort(ids.(%{"epic" => ""})) == ["BOS-1", "BOS-3"]

    assert [%{"progress" => %{"total" => 1}}] =
             call!(session, "list_tasks", %{"project_key" => "BOS", "kind" => "epic"})

    assert {:error, "Unknown kind \"story\". Use task or epic."} =
             call(session, "list_tasks", %{"project_key" => "BOS", "kind" => "story"})
  end
end
