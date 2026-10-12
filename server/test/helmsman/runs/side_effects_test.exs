defmodule Helmsman.Runs.SideEffectsTest do
  # add-run-lifecycle 5.1: the run's effects on its task (decision 12).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Feedback, Tasks}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.Workers.SideEffect
  alias Helmsman.Tasks.{Task, TaskEvent}

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
    [run] = runs_of(task.id)
    Map.merge(ctx, %{task: task, run: run})
  end

  defp set_run(run, changes) do
    {1, [run]} =
      Repo.update_all(from(r in Helmsman.Runs.Run, where: r.id == ^run.id, select: r),
        set: changes
      )

    run
  end

  defp side_effect(run, kind), do: perform_job(SideEffect, %{run_id: run.id, kind: kind})
  defp status(task), do: Repo.get!(Task, task.id).status

  defp auto_events(task),
    do: Repo.all(from(e in TaskEvent, where: e.task_id == ^task.id and e.auto))

  describe "auto_claim" do
    test "a new task assigned to the agent starts (scenario), once", ctx do
      run = set_run(ctx.run, status: :running)
      Events.subscribe(Events.topic(:task, ctx.task.id))
      Events.subscribe(Events.topic(:project, ctx.project.id))

      assert :ok = side_effect(run, "auto_claim")
      assert status(ctx.task) == :in_progress

      assert [%TaskEvent{from_status: :new, to_status: :in_progress, actor_id: actor_id} = event] =
               auto_events(ctx.task)

      assert actor_id == ctx.agent.id
      assert event.source_run_id == run.id

      ident = ctx.task.ident

      assert_receive {:task_transitioned,
                      %{ident: ^ident, event: %{auto: true, to: "in_progress"}}}

      assert_receive {:task_updated, %{id: ^ident, status: "in_progress"}}

      {:ok, task} = Tasks.get(ctx.alice_scope, ident)
      assert %{actor: %{name: "keel/dev"}, auto: true} = List.last(Tasks.detail(task).history)

      assert :ok = side_effect(run, "auto_claim")
      assert [_one] = auto_events(ctx.task)
    end

    test "nothing when the task was moved already or the assignee changed", ctx do
      run = set_run(ctx.run, status: :running)
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)
      assert :ok = side_effect(run, "auto_claim")
      assert auto_events(ctx.task) == []

      other = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
      [other_run] = runs_of(other.id)
      alice = human_actor(ctx.workspace, ctx.alice)
      {:ok, _} = Tasks.update(ctx.alice_scope, other.ident, %{assignee: alice.name})
      assert :ok = side_effect(set_run(other_run, status: :running), "auto_claim")
      assert status(other) == :new
    end
  end

  describe "fallback" do
    test "the last output becomes the agent's comment, once (scenario)", ctx do
      run = set_run(ctx.run, status: :succeeded, summary: "Implemented X.")
      Events.subscribe(Events.topic(:task, ctx.task.id))

      assert :ok = side_effect(run, "fallback")

      assert [%Entry{content: "Implemented X.", fallback: true, kind: :comment} = entry] =
               Repo.all(from(f in Entry, where: f.task_id == ^ctx.task.id))

      assert entry.author_id == ctx.agent.id
      assert entry.source_run_id == run.id
      assert_receive {:feedback_added, %{author: %{name: "keel/dev"}}}

      assert :ok = side_effect(run, "fallback")
      assert Repo.aggregate(from(f in Entry, where: f.task_id == ^ctx.task.id), :count) == 1
    end

    test "not when the run wrote feedback (scenario)", ctx do
      run = set_run(ctx.run, status: :running, capabilities: ["read", "write_task"])
      {scope, _token} = run_scope_fixture(run)
      {:ok, _} = Feedback.add(scope, ctx.task.ident, %{content: "Working on it."})
      run = set_run(run, status: :succeeded, summary: "Done.")

      assert :ok = side_effect(run, "fallback")
      assert Repo.aggregate(from(f in Entry, where: f.task_id == ^ctx.task.id), :count) == 1
    end

    test "not for a blank output, a failed or a cancelled run", ctx do
      for changes <- [
            [status: :succeeded, summary: "  "],
            [status: :succeeded, summary: nil],
            [status: :failed, summary: "Oops."],
            [status: :cancelled, summary: "Half."]
          ] do
        run = set_run(ctx.run, changes)
        assert :ok = side_effect(run, "fallback")
      end

      assert Repo.aggregate(from(f in Entry, where: f.task_id == ^ctx.task.id), :count) == 0
      assert status(ctx.task) == :new
    end
  end
end
