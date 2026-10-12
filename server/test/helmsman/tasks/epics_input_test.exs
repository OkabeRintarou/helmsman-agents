defmodule Helmsman.Tasks.EpicsInputTest do
  # `add-epics` decisions 3-4: kind and epic on create and update.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS")
    project_fixture(scope, key: "WEB")
    %{workspace: workspace, scope: scope}
  end

  defp errors(changeset), do: errors_on(changeset)

  defp reload(task), do: Repo.get!(Task, task.id)

  describe "epics and steps" do
    test "an epic, and a step in another project (epic ID in any case)", %{scope: scope} do
      {:ok, epic} = Tasks.create(scope, "BOS", %{title: "Login revamp", kind: "epic"})
      assert epic.kind == :epic
      assert Tasks.summary(epic).kind == "epic"

      {:ok, step} = Tasks.create(scope, "WEB", %{title: "Login form", epic: "bos-1"})
      assert step.ident == "WEB-1"
      assert step.epic_id == epic.id
      assert %{kind: "task", epic: "BOS-1"} = Tasks.summary(step)
    end

    test "kind defaults to task; an unknown kind is invalid", %{scope: scope} do
      {:ok, task} = Tasks.create(scope, "BOS", %{title: "T"})
      assert task.kind == :task
      {:ok, epic} = Tasks.create(scope, "BOS", %{"title" => "E", "kind" => "EPIC"})
      assert epic.kind == :epic

      assert {:error, changeset} = Tasks.create(scope, "BOS", %{title: "T", kind: "story"})
      assert %{kind: ["is invalid"]} = errors(changeset)
    end

    test "an epic cannot belong to an epic", %{scope: scope} do
      epic = task_fixture(scope, "BOS", kind: "epic")
      other = task_fixture(scope, "BOS", kind: "epic")

      assert {:error, changeset} = Tasks.update(scope, other.ident, %{epic: epic.ident})
      assert %{epic: ["an epic cannot belong to another epic"]} = errors(changeset)
      assert reload(other).epic_id == nil
      assert reload(other).lock_version == other.lock_version

      assert {:error, changeset} =
               Tasks.create(scope, "BOS", %{title: "E", kind: "epic", epic: epic.ident})

      assert %{epic: ["an epic cannot belong to another epic"]} = errors(changeset)
    end

    test "the target is not an epic", %{scope: scope} do
      task = task_fixture(scope, "BOS")
      other = task_fixture(scope, "BOS")

      assert {:error, changeset} = Tasks.update(scope, task.ident, %{epic: other.ident})
      assert %{epic: ["is not an epic"]} = errors(changeset)
      assert reload(task).epic_id == nil

      assert {:error, changeset} = Tasks.create(scope, "BOS", %{title: "T", epic: other.ident})
      assert %{epic: ["is not an epic"]} = errors(changeset)

      assert {:error, changeset} = Tasks.update(scope, task.ident, %{epic: task.ident})
      assert %{epic: ["is not an epic"]} = errors(changeset)
    end

    test "an unknown, malformed or foreign epic is not found", %{scope: scope} do
      task = task_fixture(scope, "BOS")

      stranger = user_fixture()
      other_workspace = workspace_fixture(stranger)
      other_scope = workspace_scope_fixture(stranger, other_workspace)
      project_fixture(other_scope, key: "OPS")
      foreign = task_fixture(other_scope, "OPS", kind: "epic")

      for ident <- ["BOS-99", "not an id", foreign.ident] do
        assert {:error, changeset} = Tasks.update(scope, task.ident, %{epic: ident})
        assert %{epic: ["not found"]} = errors(changeset)
        assert {:error, changeset} = Tasks.create(scope, "BOS", %{title: "T", epic: ident})
        assert %{epic: ["not found"]} = errors(changeset)
      end

      assert {:error, changeset} = Tasks.update(scope, task.ident, %{epic: 12})
      assert %{epic: ["is invalid"]} = errors(changeset)
      assert reload(task).lock_version == task.lock_version
    end

    test "changing the kind is an error; the same kind is no change", %{scope: scope} do
      task = task_fixture(scope, "BOS")

      assert {:error, changeset} = Tasks.update(scope, task.ident, %{kind: "epic"})
      assert %{kind: ["cannot be changed"]} = errors(changeset)
      assert reload(task).kind == :task

      assert {:error, changeset} = Tasks.update(scope, task.ident, %{kind: "story"})
      assert %{kind: ["cannot be changed"]} = errors(changeset)

      assert {:ok, same} = Tasks.update(scope, task.ident, %{kind: "TASK"})
      assert same.lock_version == task.lock_version
    end

    test "attaching and detaching are field edits", %{scope: scope} do
      epic = task_fixture(scope, "BOS", kind: "epic")
      step = task_fixture(scope, "WEB")

      assert {:ok, step} = Tasks.update(scope, step.ident, %{"epic" => epic.ident})
      assert step.epic_id == epic.id
      assert step.lock_version == 2

      assert {:ok, same} = Tasks.update(scope, step.ident, %{epic: String.downcase(epic.ident)})
      assert same.lock_version == 2

      assert {:ok, step} = Tasks.update(scope, step.ident, %{epic: ""}, 2)
      assert step.epic_id == nil
      assert step.lock_version == 3
      assert Tasks.summary(step).epic == nil
      assert reload(epic).lock_version == epic.lock_version

      assert {:ok, step} = Tasks.update(scope, step.ident, %{epic: nil})
      assert step.lock_version == 3
    end

    test "moving a step from one epic to another", %{scope: scope} do
      first = task_fixture(scope, "BOS", kind: "epic")
      second = task_fixture(scope, "WEB", kind: "epic")
      step = task_fixture(scope, "WEB", epic: first.ident)

      assert {:ok, step} = Tasks.update(scope, step.ident, %{epic: second.ident})
      assert step.epic_id == second.id
    end

    test "an empty epic on create attaches nothing", %{scope: scope} do
      assert {:ok, task} = Tasks.create(scope, "BOS", %{title: "T", epic: ""})
      assert task.epic_id == nil
    end

    test "a stale version with epic is stale, checked first", %{scope: scope} do
      epic = task_fixture(scope, "BOS", kind: "epic")
      task = task_fixture(scope, "BOS")
      {:ok, _} = Tasks.update(scope, task.ident, %{title: "Changed"})

      assert {:error, :stale} = Tasks.update(scope, task.ident, %{epic: epic.ident}, 1)
      assert {:error, :stale} = Tasks.update(scope, task.ident, %{epic: "BOS-99"}, 1)
    end
  end

  describe "run scopes" do
    setup do
      ctx = dispatch_fixture()
      epic = task_fixture(ctx.alice_scope, ctx.project.key, kind: "epic")
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      Map.merge(ctx, %{epic: epic, task: task})
    end

    test "create_tasks creates a step; write_task attaches its own task", ctx do
      run =
        run_fixture(ctx.agent, %{
          task_id: ctx.task.id,
          status: :running,
          capabilities: ["read", "write_task", "create_tasks"]
        })

      {scope, _token} = run_scope_fixture(run)

      assert {:ok, step} =
               Tasks.create(scope, ctx.project.key, %{title: "Sub", epic: ctx.epic.ident})

      assert step.epic_id == ctx.epic.id

      assert {:ok, task} = Tasks.update(scope, ctx.task.ident, %{epic: ctx.epic.ident})
      assert task.epic_id == ctx.epic.id

      assert {:error, :forbidden} = Tasks.update(scope, step.ident, %{epic: ""})
    end
  end
end

defmodule Helmsman.Tasks.EpicsInputLockTest do
  # Lock order of edits with and without `epic` (decision 4), on
  # connections of their own outside the sandbox.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{CommittedData, LockHarness, Locks, Repo, Tasks}

  setup do
    tag = System.unique_integer([:positive])

    {owner, scope, epic, other_epic, task} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@epics-lock.test"})
        workspace = workspace_fixture(owner)
        scope = workspace_scope_fixture(owner, workspace)
        project_fixture(scope, key: "BOS")
        epic = task_fixture(scope, "BOS", kind: "epic")
        other_epic = task_fixture(scope, "BOS", kind: "epic")
        task = task_fixture(scope, "BOS", epic: epic.ident)
        {:ok, _} = Tasks.update(scope, task.ident, %{title: "v2"})
        {owner, scope, epic, other_epic, task}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)
    %{scope: scope, epic: epic, other_epic: other_epic, task: task}
  end

  defp run_unboxed(fun), do: Task.async(fn -> CommittedData.unboxed(fun) end)

  test "stale with epic: the epic rows are never locked", ctx do
    holder =
      LockHarness.start(
        fn ->
          Repo.query!("SELECT id FROM tasks WHERE id = ANY($1) FOR UPDATE", [
            [ctx.epic.id, ctx.other_epic.id]
          ])

          :ok
        end,
        pause: :commit
      )

    LockHarness.await_paused(holder)

    edit =
      run_unboxed(fn ->
        Tasks.update(ctx.scope, ctx.task.ident, %{epic: ctx.other_epic.ident}, 1)
      end)

    assert {:ok, {:error, :stale}} = Task.yield(edit, 1_000)
    LockHarness.continue(holder)
    assert :ok = LockHarness.result(holder)
  end

  test "an edit without epic does not take the graph lock; one with it does", ctx do
    holder =
      LockHarness.start(fn -> Locks.graph!(ctx.scope.workspace.id) end, pause: :commit)

    LockHarness.await_paused(holder)

    title = run_unboxed(fn -> Tasks.update(ctx.scope, ctx.task.ident, %{title: "v3"}) end)
    assert {:ok, {:ok, %{title: "v3"}}} = Task.yield(title, 1_000)

    epic =
      LockHarness.start(fn -> Tasks.update(ctx.scope, ctx.task.ident, %{epic: ""}) end)

    LockHarness.await_blocked(epic)
    LockHarness.continue(holder)
    assert :ok = LockHarness.result(holder)
    assert {:ok, %{epic_id: nil}} = LockHarness.result(epic)
  end
end
