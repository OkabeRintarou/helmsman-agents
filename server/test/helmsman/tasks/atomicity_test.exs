defmodule Helmsman.Tasks.AtomicityTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Events
  alias Helmsman.Projects
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Task, TaskEvent}
  alias Helmsman.Tx

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project = project_fixture(scope, key: "BOS")
    Events.subscribe(Events.topic(:project, project.id))
    %{scope: scope, project: project}
  end

  # The project's task_seq, its tasks and the workspace's history entries.
  defp counts(scope, project) do
    {:ok, %{task_seq: seq}} = Projects.get(scope, "BOS")

    {seq, Repo.aggregate(where(Task, project_id: ^project.id), :count),
     Repo.aggregate(where(TaskEvent, workspace_id: ^project.workspace_id), :count)}
  end

  test "a failure after the number is allocated rolls everything back",
       %{scope: scope, project: project} do
    before = counts(scope, project)

    Process.put(:helmsman_test_hook, fn
      :seq_allocated ->
        # The number is taken inside the transaction at this point.
        assert %{rows: [[1]]} =
                 Repo.query!("SELECT task_seq FROM projects WHERE id = $1", [project.id])

        raise "boom"

      _other ->
        :ok
    end)

    assert_raise RuntimeError, "boom", fn -> Tasks.create(scope, "BOS", %{title: "T"}) end
    Process.delete(:helmsman_test_hook)

    assert counts(scope, project) == before
    refute_receive {:task_created, _}

    assert {:ok, %Task{ident: "BOS-1"}} = Tasks.create(scope, "BOS", %{title: "T"})
    assert_receive {:task_created, %{id: "BOS-1"}}
  end

  test "an outer transaction that fails rolls a successful creation back",
       %{scope: scope, project: project} do
    before = counts(scope, project)

    assert Tx.run(fn ->
             {:ok, %Task{ident: "BOS-1"}} = Tasks.create(scope, "BOS", %{title: "T"})
             {:error, :boom}
           end) == {:error, :boom}

    assert counts(scope, project) == before
    refute_receive {:task_created, _}

    assert {:ok, %Task{ident: "BOS-1"}} = Tasks.create(scope, "BOS", %{title: "T"})
  end
end
