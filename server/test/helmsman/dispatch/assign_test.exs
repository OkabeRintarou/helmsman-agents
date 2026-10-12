defmodule Helmsman.Dispatch.AssignTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Events
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.{Outcome, Run, TaskGrant}
  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, task: task})
  end

  defp grants(task_id), do: Repo.all(from(g in TaskGrant, where: g.task_id == ^task_id))

  defp assign(scope, task, attrs \\ %{}),
    do: Tasks.update(scope, task.ident, Map.merge(%{assignee: "keel/dev"}, attrs))

  describe "assignment" do
    test "to a managed agent: a queued work run on alice's behalf", ctx do
      assert {:ok, task} = assign(ctx.alice_scope, ctx.task)

      assert [%Outcome{agent: "keel/dev", trigger: :assign, result: :queued, run_id: id}] =
               task.dispatch

      assert [%Run{id: ^id, lane: :work, status: :queued} = run] = runs_of(task.id)
      assert run.root_initiator_user_id == ctx.alice.id
      assert [%{"kind" => "assign", "by_actor_id" => by}] = run.triggers
      assert by == ctx.alice_scope.actor.id

      assert [%TaskGrant{kind: :assign, root_initiator_user_id: root, causal_agent_ids: chain}] =
               grants(task.id)

      assert {root, chain} == {ctx.alice.id, [ctx.agent.id]}
    end

    test "creating a task with the agent as assignee dispatches too", ctx do
      assert {:ok, task} =
               Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "T", assignee: "keel/dev"})

      assert [%Outcome{result: :queued}] = task.dispatch
      assert [%Run{}] = runs_of(task.id)

      assert {:ok, task} =
               Tasks.create(ctx.alice_scope, ctx.project.key, %{
                 title: "T",
                 assignee: "keel/dev",
                 start: false
               })

      assert [%Outcome{result: :skipped, reason: :not_started}] = task.dispatch
      assert runs_of(task.id) == []
    end

    test "start: false records the grant, no run", ctx do
      assert {:ok, task} = assign(ctx.alice_scope, ctx.task, %{start: false})
      assert [%Outcome{result: :skipped, reason: :not_started}] = task.dispatch
      assert runs_of(task.id) == []
      assert [%TaskGrant{root_initiator_user_id: root}] = grants(task.id)
      assert root == ctx.alice.id
    end

    test "a closed task: task_closed", ctx do
      Repo.update_all(from(t in Task, where: t.id == ^ctx.task.id), set: [status: :done])
      assert {:ok, task} = assign(ctx.alice_scope, ctx.task)
      assert [%Outcome{result: :skipped, reason: :task_closed}] = task.dispatch
      assert runs_of(task.id) == []
      assert [_grant] = grants(task.id)
    end

    test "a stale lock_version: stale, no run", ctx do
      assert {:error, :stale} =
               Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "keel/dev"}, 99)

      assert runs_of(ctx.task.id) == []
      assert grants(ctx.task.id) == []
    end

    test "unauthorized: the assignee is saved, no run", ctx do
      assert {:ok, task} = assign(ctx.bob_scope, ctx.task)
      assert task.assignee.name == "keel/dev"
      assert [%Outcome{result: :skipped, reason: :unauthorized}] = task.dispatch
      assert runs_of(task.id) == []
    end
  end

  describe "grants" do
    test "reassigning to a person removes the grant", ctx do
      {:ok, _} = assign(ctx.alice_scope, ctx.task)
      assert [_] = grants(ctx.task.id)

      bob_name = ctx.bob_scope.actor.name
      assert {:ok, task} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: bob_name})
      assert task.dispatch == []
      assert grants(ctx.task.id) == []
    end

    test "an unauthorized assignment leaves no grant, start: false included", ctx do
      assert {:ok, task} = assign(ctx.bob_scope, ctx.task, %{start: false})
      assert [%Outcome{result: :skipped, reason: :unauthorized}] = task.dispatch
      assert grants(ctx.task.id) == []
    end
  end

  describe "no dispatch" do
    test "an edit that keeps the assignee, or only gives start", ctx do
      {:ok, task} = assign(ctx.alice_scope, ctx.task)
      version = task.lock_version

      assert {:ok, task} =
               Tasks.update(ctx.alice_scope, task.ident, %{title: "New", assignee: "keel/dev"})

      assert task.dispatch == []
      assert task.lock_version == version + 1

      for start <- [true, false, nil] do
        assert {:ok, same} = Tasks.update(ctx.alice_scope, task.ident, %{"start" => start})
        assert same.dispatch == []
        assert same.lock_version == version + 1
      end

      assert [%Run{triggers: [_]}] = runs_of(task.id)
    end

    test "start must be a boolean", ctx do
      assert {:error, changeset} = assign(ctx.alice_scope, ctx.task, %{start: "yes"})
      assert %{start: ["is invalid"]} = errors_on(changeset)
      assert runs_of(ctx.task.id) == []

      assert {:error, changeset} =
               Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "T", start: 1})

      assert %{start: ["is invalid"]} = errors_on(changeset)
    end

    test "a person or an external agent", ctx do
      agent_fixture(ctx.workspace, ctx.alice, "keel/external")

      for name <- [ctx.bob_scope.actor.name, "keel/external"] do
        assert {:ok, task} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: name})
        assert task.dispatch == []
      end

      assert runs_of(ctx.task.id) == []
    end

    test "claiming a new task in a transition never dispatches", ctx do
      run =
        run_fixture(ctx.agent, %{
          task_id: ctx.task.id,
          status: :running,
          capabilities: ["read", "write_task"]
        })

      {scope, _token} = run_scope_fixture(run)

      assert {:ok, %{assignee: %{name: "keel/dev"}}} =
               Tasks.transition(scope, ctx.task.ident, :in_progress)

      assert [%Run{id: id}] = runs_of(ctx.task.id)
      assert id == run.id
      assert grants(ctx.task.id) == []
    end
  end

  test "A → B → A from a run: loop_detected, the assignee and the system comment commit", ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/review"})
    review = agent_actor(ctx.workspace, "keel/review")

    run =
      run_fixture(review, %{
        task_id: ctx.task.id,
        status: :running,
        causal_agent_ids: [ctx.agent.id, review.id],
        capabilities: ["read", "write_task"]
      })

    {scope, _token} = run_scope_fixture(run)
    Events.subscribe(Events.topic(:task, ctx.task.id))

    assert {:ok, task} = assign(scope, ctx.task)
    assert task.assignee.name == "keel/dev"
    assert [%Outcome{result: :skipped, reason: :loop_detected}] = task.dispatch
    assert task.feedback_count == 1

    assert [%Entry{author_id: author_id, content: content}] =
             Repo.all(from(f in Entry, where: f.task_id == ^ctx.task.id))

    assert Repo.get!(Helmsman.Actors.Actor, author_id).name == "helmsman"
    assert content =~ "(keel/dev → keel/review)"
    assert [%Run{id: id}] = runs_of(ctx.task.id)
    assert id == run.id
    assert grants(ctx.task.id) == []

    assert_receive {:feedback_added, %{author: %{name: "helmsman"}}}
    refute_receive {:feedback_added, _}
  end
end
