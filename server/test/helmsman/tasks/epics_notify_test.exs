defmodule Helmsman.Tasks.EpicsNotifyTest do
  # `add-epics` decision 9: notifications of an epic whose steps change.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Events, Tasks}

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    bos = project_fixture(scope, key: "BOS")
    project_fixture(scope, key: "WEB")
    epic = task_fixture(scope, "BOS", kind: "epic")
    Events.subscribe(Events.topic(:project, bos.id))
    Events.subscribe(Events.topic(:task, epic.id))
    %{scope: scope, epic: epic}
  end

  defp move(scope, task, path),
    do: Enum.each(path, &({:ok, _} = Tasks.transition(scope, task.ident, &1)))

  # Every message about `ident` received so far.
  defp drain(ident, acc \\ []) do
    receive do
      {:task_updated, %{id: ^ident}} = message -> drain(ident, [message | acc])
      {:task_updated, ^ident} = message -> drain(ident, [message | acc])
      {:task_transitioned, %{ident: ^ident}} = message -> drain(ident, [message | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "a step done, the epic still open: updated, not transitioned", %{scope: scope, epic: epic} do
    [a, _b] = for _ <- 1..2, do: task_fixture(scope, "WEB", epic: epic.ident)
    move(scope, a, [:in_progress])
    drain(epic.ident)

    move(scope, a, [:done])

    ident = epic.ident

    assert [
             {:task_updated, %{id: ^ident, status: "new", progress: %{done: 1, total: 2}}},
             {:task_updated, ^ident}
           ] = drain(ident)
  end

  test "an automatic transition is announced on the epic topic", %{scope: scope, epic: epic} do
    [step] = for _ <- 1..1, do: task_fixture(scope, "WEB", epic: epic.ident)
    move(scope, step, [:in_progress])
    drain(epic.ident)

    move(scope, step, [:done])

    ident = epic.ident

    assert [
             {:task_updated, %{id: ^ident, status: "done", progress: %{done: 1}}},
             {:task_updated, ^ident},
             {:task_transitioned,
              %{
                ident: ^ident,
                event: %{
                  from: "new",
                  to: "done",
                  auto: true,
                  comment: "all steps completed (auto)"
                }
              }}
           ] = drain(ident)
  end

  test "creating a step notifies once", %{scope: scope, epic: epic} do
    task_fixture(scope, "WEB", epic: epic.ident)
    ident = epic.ident
    assert [{:task_updated, %{id: ^ident}}, {:task_updated, ^ident}] = drain(ident)

    task_fixture(scope, "WEB")
    assert drain(ident) == []
  end

  test "moving a step: each epic once", %{scope: scope, epic: epic} do
    other = task_fixture(scope, "BOS", kind: "epic")
    Events.subscribe(Events.topic(:task, other.id))
    step = task_fixture(scope, "WEB", epic: epic.ident)
    drain(epic.ident)

    {:ok, _} = Tasks.update(scope, step.ident, %{epic: other.ident})

    {ident, other_ident} = {epic.ident, other.ident}

    assert [{:task_updated, %{id: ^ident, progress: %{total: 0}}}, {:task_updated, ^ident}] =
             drain(ident)

    assert [
             {:task_updated, %{id: ^other_ident, progress: %{total: 1}}},
             {:task_updated, ^other_ident}
           ] = drain(other_ident)
  end

  test "a field edit of a step or a failed write sends nothing", %{scope: scope, epic: epic} do
    step = task_fixture(scope, "WEB", epic: epic.ident)
    other = task_fixture(scope, "WEB")
    drain(epic.ident)

    {:ok, _} = Tasks.update(scope, step.ident, %{title: "Renamed"})
    assert {:error, :stale} = Tasks.update(scope, step.ident, %{epic: ""}, 1)
    assert {:error, _changeset} = Tasks.update(scope, other.ident, %{epic: "BOS-99"})
    assert {:error, _changeset} = Tasks.update(scope, other.ident, %{epic: epic.ident, title: ""})
    assert {:error, _changeset} = Tasks.create(scope, "WEB", %{title: "", epic: epic.ident})

    refute_receive {:task_updated, _}
    refute_receive {:task_transitioned, _}
  end
end
