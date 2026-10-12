defmodule Helmsman.Tasks.ListAssignedTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Tasks

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS")
    project_fixture(scope, key: "KEEL")
    keel = agent_fixture(workspace, owner, "keel/dev")
    agent = %{scope | actor: keel}

    bos1 = task_fixture(scope, "BOS", assignee: "keel/dev")
    {:ok, _} = Tasks.transition(agent, bos1.ident, :in_progress)
    keel2 = task_fixture(scope, "KEEL", assignee: "keel/dev")
    bos3 = task_fixture(scope, "BOS", assignee: "keel/dev")
    {:ok, _} = Tasks.transition(agent, bos3.ident, :in_progress)
    {:ok, _} = Tasks.transition(agent, bos3.ident, :done)
    # Someone else's task and an unassigned one.
    task_fixture(scope, "BOS", assignee: scope.actor.name)
    task_fixture(scope, "BOS")

    %{scope: scope, agent: agent, owner: owner, ids: {bos1.ident, keel2.ident, bos3.ident}}
  end

  defp ids({:ok, summaries}), do: Enum.map(summaries, & &1.id)

  test "new and in_progress tasks across projects by default",
       %{agent: agent, ids: {bos1, keel2, _bos3}} do
    assert {:ok, [%{id: ^keel2, status: "new"}, %{id: ^bos1, status: "in_progress"}]} =
             Tasks.list_assigned(agent)
  end

  test "a given status, in any spelling", %{agent: agent, ids: {bos1, _keel2, bos3}} do
    assert ids(Tasks.list_assigned(agent, status: "done")) == [bos3]
    assert ids(Tasks.list_assigned(agent, status: ["DONE", "in progress"])) == [bos3, bos1]
  end

  test "most recently updated first", %{agent: agent, ids: {bos1, keel2, _bos3}} do
    {:ok, _} = Tasks.update(agent, bos1, %{title: "Touched"})
    assert ids(Tasks.list_assigned(agent)) == [bos1, keel2]
  end

  test "no identity", %{scope: scope} do
    assert Tasks.list_assigned(%{scope | actor: nil}) == {:error, :no_identity}
  end

  test "an unknown status", %{agent: agent} do
    assert {:error, {:invalid_status, "doing", [_ | _]}} =
             Tasks.list_assigned(agent, status: ["done", "doing"])
  end

  test "not another workspace's tasks of a same-named agent", %{owner: owner, agent: agent} do
    other = workspace_fixture(owner)
    other_scope = workspace_scope_fixture(owner, other)
    project_fixture(other_scope, key: "BOS")
    other_keel = agent_fixture(other, owner, "keel/dev")
    task_fixture(other_scope, "BOS", assignee: "keel/dev")

    assert {:ok, [_, _]} = Tasks.list_assigned(agent)
    assert ids(Tasks.list_assigned(%{other_scope | actor: other_keel})) == ["BOS-1"]
  end
end
