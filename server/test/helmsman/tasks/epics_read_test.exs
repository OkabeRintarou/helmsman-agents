defmodule Helmsman.Tasks.EpicsReadTest do
  # `add-epics` decisions 5 and 8: progress, summary, detail and list.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Tasks
  alias Helmsman.Tasks.Epics

  @tests %{command: "mix test", passed: true, summary: "1 test, 0 failures"}

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS")
    project_fixture(scope, key: "WEB")
    %{workspace: workspace, scope: scope}
  end

  defp move(scope, task, path) do
    Enum.each(path, fn to ->
      opts = if to == :verified, do: %{tests: @tests}, else: %{}
      {:ok, _} = Tasks.transition(scope, task.ident, to, opts)
    end)
  end

  defp ids(tasks), do: Enum.map(tasks, & &1.ident)

  describe "progress" do
    test "done and verified complete; cancelled and rejected count", %{scope: scope} do
      epic = task_fixture(scope, "BOS", kind: "epic")

      [done, verified, cancelled, started] =
        for _ <- 1..4, do: task_fixture(scope, "BOS", epic: epic.ident)

      move(scope, done, [:in_progress, :done])
      move(scope, verified, [:in_progress, :done, :verified])
      move(scope, cancelled, [:cancelled])
      move(scope, started, [:in_progress])

      assert {:ok, epic} = Tasks.get(scope, epic.ident)

      assert %{
               total: 4,
               done: 2,
               by_status: %{
                 "new" => 0,
                 "in_progress" => 1,
                 "done" => 1,
                 "verified" => 1,
                 "rejected" => 0,
                 "cancelled" => 1
               }
             } = Tasks.summary(epic).progress
    end

    test "rejected steps count in the total", %{scope: scope, workspace: workspace} do
      epic = task_fixture(scope, "BOS", kind: "epic")
      step = task_fixture(scope, "BOS", epic: epic.ident)
      move(scope, step, [:in_progress, :rejected])

      epic_id = epic.id

      assert %{^epic_id => %{total: 1, done: 0, by_status: %{"rejected" => 1}}} =
               Epics.progress(workspace.id, [epic.id])
    end

    test "an epic without steps; a task has none", %{scope: scope, workspace: workspace} do
      epic = task_fixture(scope, "BOS", kind: "epic")
      task = task_fixture(scope, "BOS")

      assert %{total: 0, done: 0} = Tasks.summary(epic).progress
      assert Tasks.summary(task).progress == nil
      assert Epics.progress(workspace.id, []) == %{}
    end

    test "follows attaching and detaching", %{scope: scope} do
      epic = task_fixture(scope, "BOS", kind: "epic")
      step = task_fixture(scope, "WEB")

      {:ok, _} = Tasks.update(scope, step.ident, %{epic: epic.ident})
      {:ok, read} = Tasks.get(scope, epic.ident)
      assert Tasks.summary(read).progress.total == 1

      {:ok, _} = Tasks.update(scope, step.ident, %{epic: ""})
      {:ok, read} = Tasks.get(scope, epic.ident)
      assert Tasks.summary(read).progress.total == 0
    end
  end

  describe "reading an epic" do
    test "children in creation order across projects, with progress", %{scope: scope} do
      epic = task_fixture(scope, "BOS", kind: "epic")
      web = task_fixture(scope, "WEB", epic: epic.ident)
      task_fixture(scope, "BOS")
      bos = task_fixture(scope, "BOS", epic: epic.ident)
      # Updated last, still listed by creation.
      {:ok, _} = Tasks.update(scope, web.ident, %{title: "Login form"})

      {:ok, read} = Tasks.get(scope, epic.ident)
      detail = Tasks.detail(read)

      assert Enum.map(detail.children, & &1.id) == [web.ident, bos.ident]
      assert [%{epic: "BOS-1", project_key: "WEB", title: "Login form"}, _] = detail.children
      assert detail.progress.total == 2
      assert detail.kind == "epic"
      assert detail.epic_title == nil
    end

    test "a step's detail has its epic's title; a task's has none", %{scope: scope} do
      epic = task_fixture(scope, "BOS", kind: "epic", title: "Login revamp")
      step = task_fixture(scope, "WEB", epic: epic.ident)
      task = task_fixture(scope, "WEB")

      {:ok, read} = Tasks.get(scope, step.ident)
      assert %{epic: "BOS-1", epic_title: "Login revamp", children: nil} = Tasks.detail(read)

      {:ok, read} = Tasks.get(scope, task.ident)
      assert %{epic: nil, epic_title: nil, children: nil} = Tasks.detail(read)
    end
  end

  describe "list/3" do
    setup %{scope: scope} do
      epic = task_fixture(scope, "BOS", kind: "epic")
      other_epic = task_fixture(scope, "BOS", kind: "epic")
      bos_step = task_fixture(scope, "BOS", epic: epic.ident)
      web_step = task_fixture(scope, "WEB", epic: epic.ident)
      other_step = task_fixture(scope, "BOS", epic: other_epic.ident)
      loose = task_fixture(scope, "BOS")

      %{
        epic: epic,
        other_epic: other_epic,
        bos_step: bos_step,
        web_step: web_step,
        other_step: other_step,
        loose: loose
      }
    end

    test "by epic: only the steps of the project", ctx do
      assert {:ok, tasks} = Tasks.list(ctx.scope, "BOS", epic: "bos-1")
      assert ids(tasks) == [ctx.bos_step.ident]
      assert {:ok, [web]} = Tasks.list(ctx.scope, "WEB", epic: ctx.epic.ident)
      assert web.ident == ctx.web_step.ident
      assert Tasks.summary(web).epic == ctx.epic.ident
    end

    test "\"\" for tasks in no epic; unknown epics match nothing", ctx do
      assert {:ok, tasks} = Tasks.list(ctx.scope, "BOS", epic: "")

      assert Enum.sort(ids(tasks)) ==
               Enum.sort([ctx.epic.ident, ctx.other_epic.ident, ctx.loose.ident])

      assert {:ok, []} = Tasks.list(ctx.scope, "BOS", epic: "BOS-99")
      assert {:ok, []} = Tasks.list(ctx.scope, "BOS", epic: "nonsense")
      assert {:ok, []} = Tasks.list(ctx.scope, "BOS", epic: ctx.loose.ident)
    end

    test "by kind", ctx do
      assert {:ok, epics} = Tasks.list(ctx.scope, "BOS", kind: :epic)
      assert Enum.sort(ids(epics)) == Enum.sort([ctx.epic.ident, ctx.other_epic.ident])
      totals = Map.new(epics, &{&1.ident, Tasks.summary(&1).progress.total})
      assert totals == %{ctx.epic.ident => 2, ctx.other_epic.ident => 1}

      assert {:ok, tasks} = Tasks.list(ctx.scope, "BOS", kind: "TASK")

      assert Enum.sort(ids(tasks)) ==
               Enum.sort([ctx.bos_step.ident, ctx.other_step.ident, ctx.loose.ident])

      assert {:error, {:invalid, :kind}} = Tasks.list(ctx.scope, "BOS", kind: "bogus")
      assert {:error, {:invalid, :kind}} = Tasks.list(ctx.scope, "BOS", kind: :story)
    end
  end

  test "50 epics cost one more query than 50 tasks", %{scope: scope} do
    project_fixture(scope, key: "EPX")
    project_fixture(scope, key: "TSK")

    for _ <- 1..50 do
      epic = task_fixture(scope, "EPX", kind: "epic")
      task_fixture(scope, "WEB", epic: epic.ident)
      task_fixture(scope, "TSK")
    end

    {{:ok, epics}, epic_queries} = count_queries(fn -> Tasks.list(scope, "EPX") end)
    {{:ok, tasks}, task_queries} = count_queries(fn -> Tasks.list(scope, "TSK") end)

    assert length(epics) == 50 and length(tasks) == 50
    assert Enum.all?(epics, &(Tasks.summary(&1).progress.total == 1))
    assert epic_queries == task_queries + 1
  end

  defp count_queries(fun) do
    test_pid = self()
    handler = "epics-queries-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:helmsman, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == test_pid, do: send(test_pid, :epics_query)
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(n) do
    receive do
      :epics_query -> drain(n + 1)
    after
      0 -> n
    end
  end
end
