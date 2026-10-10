defmodule Helmsman.Tasks.TransitionTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Events
  alias Helmsman.Tasks
  alias Helmsman.Tasks.TaskEvent

  @passing %{command: "mix test", passed: true, summary: "12 tests, 0 failures"}
  @statuses [:new, :in_progress, :done, :verified, :rejected, :cancelled]

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)

    [alice, viewer] =
      for role <- [:member, :viewer] do
        user = user_fixture()
        member_fixture(workspace, user, role)
        workspace_scope_fixture(user, workspace)
      end

    project = project_fixture(owner_scope, key: "BOS", name: "Bosun")
    keel = %{alice | actor: agent_fixture(workspace, alice.user, "keel/dev")}
    feature = %{alice | actor: agent_fixture(workspace, alice.user, "alice/feature-x")}

    %{
      owner: owner_scope,
      alice: alice,
      viewer: viewer,
      keel: keel,
      feature: feature,
      project: project
    }
  end

  defp new_task(scope, attrs \\ %{}), do: task_fixture(scope, "BOS", attrs)

  # Applies the transitions in order, each as `scope`, asserting success.
  defp move!(task, steps) do
    Enum.reduce(steps, nil, fn {scope, to, opts}, _ ->
      assert {:ok, detail} = Tasks.transition(scope, task.ident, to, opts)
      detail
    end)
  end

  defp reload(scope, task) do
    {:ok, task} = Tasks.get(scope, task.ident)
    task
  end

  defp history_count(task),
    do: Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^task.id), :count)

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp refute_notified do
    refute_receive {:task_updated, _}
    refute_receive {:task_transitioned, _}
  end

  defp subscribe(task) do
    Events.subscribe(Events.topic(:project, task.project_id))
    Events.subscribe(Events.topic(:task, task.id))
  end

  describe "the transition table" do
    test "a legal transition", %{alice: alice} do
      task = new_task(alice)

      assert {:ok, %{id: ident, status: "in_progress"}} =
               Tasks.transition(alice, task.ident, "in_progress")

      assert ident == task.ident
      assert reload(alice, task).status == :in_progress
    end

    test "an illegal transition lists the allowed statuses", %{alice: alice} do
      task = new_task(alice)
      move!(task, [{alice, :in_progress, %{}}, {alice, :done, %{}}])

      assert Tasks.transition(alice, task.ident, "cancelled") ==
               {:error, {:invalid_transition, :done, :cancelled, [:verified, :in_progress]}}

      assert reload(alice, task).status == :done
    end

    test "moving to the current status is illegal", %{alice: alice} do
      task = new_task(alice)

      assert {:error, {:invalid_transition, :new, :new, _}} =
               Tasks.transition(alice, task.ident, "new")

      assert history_count(task) == 1
    end

    test "unknown tasks, other workspaces and scopes without an actor", ctx do
      task = new_task(ctx.alice)
      assert Tasks.transition(ctx.alice, "BOS-99", "in_progress") == {:error, :not_found}
      assert Tasks.transition(ctx.alice, "nope", "in_progress") == {:error, :not_found}

      other = user_fixture()
      other_scope = workspace_scope_fixture(other, workspace_fixture(other))
      assert Tasks.transition(other_scope, task.ident, "in_progress") == {:error, :not_found}

      no_actor = %{ctx.alice | actor: nil}
      assert Tasks.transition(no_actor, task.ident, "in_progress") == {:error, :no_actor}
    end
  end

  describe "status names" do
    test "aliases and any case", %{alice: alice} do
      task = new_task(alice)
      assert {:ok, %{status: "in_progress"}} = Tasks.transition(alice, task.ident, "In Progress")
    end

    test "an unknown status lists the six", %{alice: alice} do
      task = new_task(alice)

      assert Tasks.transition(alice, task.ident, "doing") ==
               {:error, {:invalid_status, "doing", @statuses}}
    end
  end

  test "viewers may not transition", %{alice: alice, viewer: viewer} do
    task = new_task(alice)
    assert Tasks.transition(viewer, task.ident, "in_progress") == {:error, :forbidden}
    assert reload(alice, task).status == :new
  end

  describe "claiming" do
    test "an unassigned task gets the acting identity, and a new version",
         %{alice: alice, keel: keel} do
      task = new_task(alice)

      assert {:ok, %{assignee: %{name: "keel/dev", kind: "agent"}, lock_version: 2}} =
               Tasks.transition(keel, task.ident, "in progress")
    end

    test "an assigned task keeps its assignee and version", %{alice: alice} do
      task = new_task(alice, %{assignee: "keel/dev"})

      assert {:ok, %{assignee: %{name: "keel/dev"}, lock_version: 1}} =
               Tasks.transition(alice, task.ident, "in_progress")
    end

    test "other transitions change neither", %{alice: alice, keel: keel} do
      task = new_task(alice)
      move!(task, [{keel, :in_progress, %{}}])

      detail =
        move!(task, [
          {alice, :done, %{}},
          {alice, :in_progress, %{}},
          {alice, :cancelled, %{}},
          {alice, :new, %{}},
          {alice, :rejected, %{}},
          {alice, :new, %{}}
        ])

      assert %{assignee: %{name: "keel/dev"}, lock_version: 2, status: "new"} = detail
    end
  end

  describe "evidence" do
    test "commits are downcased and deduplicated", %{alice: alice} do
      task = new_task(alice)
      move!(task, [{alice, :in_progress, %{}}])

      assert {:ok, %{history: history}} =
               Tasks.transition(alice, task.ident, "done", %{
                 commits: ["ABC1234", "abc1234", "def5678"]
               })

      assert List.last(history).commits == ["abc1234", "def5678"]
    end

    test "an invalid commit changes nothing", %{alice: alice} do
      task = new_task(alice)
      move!(task, [{alice, :in_progress, %{}}])
      subscribe(task)

      assert Tasks.transition(alice, task.ident, "done", commits: ["xyz"]) ==
               {:error, {:invalid_commits, "xyz"}}

      assert Tasks.transition(alice, task.ident, "done", commits: ["abc1234", nil]) ==
               {:error, {:invalid_commits, nil}}

      assert reload(alice, task).status == :in_progress
      assert history_count(task) == 2
      refute_notified()
    end

    test "passed must be a boolean", %{alice: alice} do
      task = new_task(alice)
      move!(task, [{alice, :in_progress, %{}}])

      assert {:error, {:invalid_tests, _}} =
               Tasks.transition(alice, task.ident, "done", %{tests: %{@passing | passed: "yes"}})

      assert reload(alice, task).status == :in_progress
      assert history_count(task) == 2
    end
  end

  describe "self-verification" do
    setup %{alice: alice} do
      %{task: new_task(alice, %{assignee: "keel/dev"})}
    end

    test "the assignee without tests is refused", %{task: task, keel: keel} do
      move!(task, [{keel, :in_progress, %{}}, {keel, :done, %{}}])
      subscribe(task)

      assert Tasks.transition(keel, task.ident, "verified") ==
               {:error, {:self_verify_requires_tests, "keel/dev"}}

      assert reload(keel, task).status == :done
      assert history_count(task) == 3
      refute_notified()
    end

    test "the assignee with passing tests at done may verify", %{task: task, keel: keel} do
      move!(task, [{keel, :in_progress, %{}}, {keel, :done, %{tests: @passing}}])
      assert {:ok, %{status: "verified"}} = Tasks.transition(keel, task.ident, "verified")
    end

    test "an older passing result no longer counts", %{keel: keel, alice: alice} do
      for second_done <- [%{}, %{tests: %{@passing | passed: false}}] do
        task = new_task(alice, %{assignee: "keel/dev"})

        move!(task, [
          {keel, :in_progress, %{}},
          {keel, :done, %{tests: @passing}},
          {alice, :in_progress, %{comment: "not yet"}},
          {keel, :done, second_done}
        ])

        flush()
        subscribe(task)

        assert Tasks.transition(keel, task.ident, "verified") ==
                 {:error, {:self_verify_requires_tests, "keel/dev"}}

        assert reload(keel, task).status == :done
        assert history_count(task) == 5
        refute_notified()

        assert {:ok, %{status: "verified"}} =
                 Tasks.transition(keel, task.ident, "verified", %{tests: @passing})
      end
    end

    test "the user verifying their own agent's task needs no tests", ctx do
      task = new_task(ctx.alice, %{assignee: "alice/feature-x"})
      move!(task, [{ctx.feature, :in_progress, %{}}, {ctx.feature, :done, %{}}])

      assert {:ok, %{status: "verified"}} = Tasks.transition(ctx.alice, task.ident, "verified")
    end
  end

  test "history and summary commits", %{alice: alice} do
    task = new_task(alice)

    move!(task, [
      {alice, :in_progress, %{}},
      {alice, :done, %{commits: ["abc1234"], tests: @passing}}
    ])

    detail = Tasks.detail(reload(alice, task))
    assert [created, started, done] = detail.history
    assert %{from: nil, to: "new", commits: [], tests: nil, auto: false} = created
    assert %{from: "new", to: "in_progress", commits: [], tests: nil, auto: false} = started

    assert %{
             from: "in_progress",
             to: "done",
             actor: %{kind: "human"},
             commits: ["abc1234"],
             tests: %{command: "mix test", passed: true, summary: "12 tests, 0 failures"},
             auto: false
           } = done

    assert detail.commits == ["abc1234"]
  end

  test "summary commits across the history: deduplicated, oldest first", %{alice: alice} do
    task = new_task(alice)

    move!(task, [
      {alice, :in_progress, %{commits: ["bbbbbbb"]}},
      {alice, :done, %{commits: ["AAAAAAA", "bbbbbbb"]}},
      {alice, :in_progress, %{}},
      {alice, :done, %{commits: ["ccccccc", "aaaaaaa"]}}
    ])

    expected = ["bbbbbbb", "aaaaaaa", "ccccccc"]
    assert Tasks.summary(reload(alice, task)).commits == expected
    assert {:ok, [listed]} = Tasks.list(alice, "BOS")
    assert Tasks.summary(listed).commits == expected
  end

  describe "notifications" do
    test "the task topic gets the history entry, the project topic the summary",
         %{alice: alice} do
      task = new_task(alice)
      move!(task, [{alice, :in_progress, %{}}])
      subscribe(task)

      assert {:ok, detail} =
               Tasks.transition(alice, task.ident, "done", %{
                 comment: "Ready",
                 commits: ["abc1234"],
                 tests: @passing
               })

      ident = task.ident
      assert_receive {:task_updated, %{id: ^ident, status: "done", commits: ["abc1234"]}}
      assert_receive {:task_transitioned, %{ident: ^ident, event: event}}

      assert event == List.last(Tasks.detail(reload(alice, task)).history)
      assert event == List.last(detail.history)
      assert %{comment: "Ready", commits: ["abc1234"], tests: %{passed: true}} = event
    end

    test "a failed transition notifies nothing", %{alice: alice} do
      task = new_task(alice)
      subscribe(task)
      assert {:error, _} = Tasks.transition(alice, task.ident, "done")
      refute_notified()
    end
  end

  describe "list/3 queries" do
    def handle_query(_event, _measurements, _metadata, pid) do
      if self() == pid, do: send(pid, :query)
    end

    defp count_queries(fun) do
      id = {__MODULE__, make_ref()}
      :telemetry.attach(id, [:helmsman, :repo, :query], &__MODULE__.handle_query/4, self())

      try do
        fun.()
      after
        :telemetry.detach(id)
      end

      count_messages(0)
    end

    defp count_messages(n) do
      receive do
        :query -> count_messages(n + 1)
      after
        0 -> n
      end
    end

    test "do not grow with the number of tasks", %{owner: owner, alice: alice} do
      project_fixture(owner, key: "ONE")
      one = task_fixture(alice, "ONE")
      Tasks.transition(alice, one.ident, "in_progress", commits: ["abc1234"])

      for _ <- 1..50 do
        task = new_task(alice)
        {:ok, _} = Tasks.transition(alice, task.ident, "in_progress", commits: ["abc1234"])
      end

      single = count_queries(fn -> assert {:ok, [_]} = Tasks.list(alice, "ONE") end)

      many =
        count_queries(fn ->
          assert {:ok, tasks} = Tasks.list(alice, "BOS")
          assert length(tasks) == 50
          assert Enum.all?(tasks, &(&1.commits == ["abc1234"]))
        end)

      assert many == single
    end
  end
end
