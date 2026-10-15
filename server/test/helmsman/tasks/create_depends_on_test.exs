defmodule Helmsman.Tasks.CreateDependsOnTest do
  # `depends_on` on create: a subtask is ordered when it is created, so a
  # squad leader (whose run may only change its own task) can lay out a
  # whole plan at once.
  use Helmsman.DataCase, async: true

  import Helmsman.DependencyFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Links, Tasks}
  alias Helmsman.Links.Link
  alias Helmsman.Tasks.Task

  setup do
    ctx = dependency_fixture()
    %{ctx: ctx, scope: ctx.alice_scope, key: ctx.project.key}
  end

  defp links_of(task),
    do:
      Repo.all(from(l in Link, where: l.from_task_id == ^task.id, select: {l.to_task_id, l.type}))

  describe "links written with the task" do
    test "the new task depends on the listed tasks, any case, once each", %{
      ctx: ctx,
      scope: scope,
      key: key
    } do
      other = task_fixture(scope, key)
      ids = [String.downcase(ctx.bos1.ident), ctx.bos1.ident, other.ident]

      assert {:ok, task} = Tasks.create(scope, key, %{title: "Next", depends_on: ids})

      assert Enum.sort(links_of(task)) ==
               Enum.sort([{ctx.bos1.id, :depends_on}, {other.id, :depends_on}])

      assert Links.waiting_for(task) == :status
    end

    test "string keys and a nil or empty list mean none", %{scope: scope, key: key} do
      assert {:ok, a} = Tasks.create(scope, key, %{"title" => "A", "depends_on" => nil})
      assert {:ok, b} = Tasks.create(scope, key, %{"title" => "B", "depends_on" => []})
      assert links_of(a) == []
      assert links_of(b) == []
    end

    test "the detail lists the dependency", %{ctx: ctx, scope: scope, key: key} do
      {:ok, task} = Tasks.create(scope, key, %{title: "Next", depends_on: [ctx.bos1.ident]})

      assert [%{type: "depends_on", direction: "out", task: ident}] =
               task |> Tasks.detail() |> Map.fetch!(:links)

      assert ident == ctx.bos1.ident
    end

    test "a task assigned to a managed agent is deferred until the prerequisite is done", %{
      ctx: ctx,
      scope: scope,
      key: key
    } do
      assert {:ok, %Task{dispatch: [%{result: :deferred}]} = task} =
               Tasks.create(scope, key, %{
                 title: "Next",
                 assignee: "keel/dev",
                 depends_on: [ctx.bos1.ident]
               })

      assert [_deferred] = runs_in(task, :deferred)
      assert runs_in(task, :queued) == []
    end

    test "with the prerequisite already done the run is queued at once", %{
      ctx: ctx,
      scope: scope,
      key: key
    } do
      put_status!(ctx.bos1, :verified)

      assert {:ok, %Task{dispatch: [%{result: :queued}]} = task} =
               Tasks.create(scope, key, %{
                 title: "Next",
                 assignee: "keel/dev",
                 depends_on: [ctx.bos1.ident]
               })

      assert [_queued] = runs_in(task, :queued)
    end

    test "an epic step can depend on a task in another project", %{
      ctx: ctx,
      scope: scope
    } do
      project_fixture(scope, key: "WEB")
      {:ok, epic} = Tasks.create(scope, ctx.project.key, %{title: "Goal", kind: "epic"})

      assert {:ok, step} =
               Tasks.create(scope, "WEB", %{
                 title: "Step",
                 epic: epic.ident,
                 depends_on: [ctx.bos1.ident]
               })

      assert step.epic_id == epic.id
      assert links_of(step) == [{ctx.bos1.id, :depends_on}]
    end
  end

  describe "invalid input" do
    test "an unknown task is an error on depends_on and nothing is created", %{
      ctx: ctx,
      scope: scope,
      key: key
    } do
      before = Repo.aggregate(Task, :count)

      assert {:error, changeset} =
               Tasks.create(scope, key, %{title: "Next", depends_on: [ctx.bos1.ident, "BOS-99"]})

      assert %{depends_on: ["BOS-99 not found"]} = errors_on(changeset)
      assert Repo.aggregate(Task, :count) == before
    end

    test "a malformed ID or a value that is not a list", %{scope: scope, key: key} do
      assert {:error, changeset} = Tasks.create(scope, key, %{title: "A", depends_on: ["nope"]})
      assert %{depends_on: ["has an invalid task ID"]} = errors_on(changeset)

      assert {:error, changeset} = Tasks.create(scope, key, %{title: "B", depends_on: [1]})
      assert %{depends_on: ["has an invalid task ID"]} = errors_on(changeset)

      assert {:error, changeset} = Tasks.create(scope, key, %{title: "C", depends_on: "BOS-1"})
      assert %{depends_on: ["is invalid"]} = errors_on(changeset)
    end

    test "a step cannot wait for its own epic", %{ctx: ctx, scope: scope, key: key} do
      {:ok, epic} = Tasks.create(scope, ctx.project.key, %{title: "Goal", kind: "epic"})

      assert {:error, changeset} =
               Tasks.create(scope, key, %{
                 title: "Step",
                 epic: epic.ident,
                 depends_on: [epic.ident]
               })

      assert %{depends_on: ["cannot include the task's own epic"]} = errors_on(changeset)
    end

    test "a task of another workspace is not found", %{scope: scope, key: key} do
      other = dependency_fixture()
      project_fixture(other.alice_scope, key: "ZZZ")
      foreign = task_fixture(other.alice_scope, "ZZZ")

      assert {:error, changeset} =
               Tasks.create(scope, key, %{title: "Next", depends_on: [foreign.ident]})

      assert %{depends_on: ["ZZZ-1 not found"]} = errors_on(changeset)
    end
  end

  describe "a run" do
    test "may order the task it creates after any task of the workspace", %{
      ctx: ctx,
      scope: scope,
      key: key
    } do
      own = task_fixture(scope, key)

      run =
        run_fixture(ctx.agent, %{
          task_id: own.id,
          status: :running,
          capabilities: ["read", "write_task", "create_tasks"]
        })

      {run_scope, _token} = run_scope_fixture(run)

      assert {:ok, task} =
               Tasks.create(run_scope, key, %{
                 title: "Sub",
                 depends_on: [ctx.bos1.ident, ctx.web2.ident]
               })

      assert Enum.sort(links_of(task)) ==
               Enum.sort([{ctx.bos1.id, :depends_on}, {ctx.web2.id, :depends_on}])
    end
  end
end
