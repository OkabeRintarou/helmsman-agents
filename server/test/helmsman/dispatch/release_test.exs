defmodule Helmsman.Dispatch.ReleaseTest do
  # add-dependency-dispatch 1.5: deferred runs released in place, in the
  # transaction that satisfies the last prerequisite (decisions 6, 11).
  use Helmsman.DataCase, async: true

  import Helmsman.DependencyFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Daemons.Runtime
  alias Helmsman.{Events, Links}
  alias Helmsman.Runs.{Run, Spec}
  alias Helmsman.Tasks

  setup do
    ctx = dependency_fixture()
    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "in_progress")
    {:ok, %{dispatch: [%{result: :deferred}]}} = assign(ctx, ctx.web2)
    [deferred] = runs_in(ctx.web2, :deferred)
    Map.put(ctx, :deferred, deferred)
  end

  defp assign(ctx, task), do: Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/dev"})

  defp prompt(run) do
    run = run |> Ecto.Changeset.change(status: :claimed) |> Repo.update!()
    {:ok, spec} = Spec.build(run, "hmr_" <> String.duplicate("a", 52), "https://hm.test")
    spec.prompt
  end

  describe "依赖满足后开始排队" do
    test "前置任务完成: queued in the same transaction, unblocked marker, prompt line", ctx do
      runtime = Repo.get!(Runtime, profile(ctx.agent).runtime_id)
      Events.subscribe(Events.topic(:daemon, runtime.daemon_id))
      Events.subscribe(Events.topic(:workspace_runs, ctx.workspace.id))
      id = ctx.deferred.id

      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "done")

      run = Repo.get!(Run, id)
      assert run.status == :queued
      assert [%{"kind" => "assign"}, %{"kind" => "unblocked"} = marker] = run.triggers
      assert marker["prerequisites"] == [ctx.bos1.ident]
      refute Map.has_key?(marker, "initiator_user_id")
      assert {run.priority, run.inserted_at} == {ctx.deferred.priority, ctx.deferred.inserted_at}

      assert_receive {:run_updated, %{id: ^id, status: "queued"}}
      assert_receive {:runs_available}

      assert prompt(run) =~
               "- The tasks #{ctx.web2.ident} depends on are finished (their changes, if any, " <>
                 "are merged into the base branch): #{ctx.bos1.ident}. You can start."
    end

    test "两个前置任务", ctx do
      bos2 = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Tasks.transition(ctx.alice_scope, bos2.ident, "in_progress")
      {:ok, _} = Links.add(ctx.alice_scope, ctx.web2.ident, bos2.ident, "depends_on")

      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "done")
      assert run_status(ctx.deferred) == :deferred

      {:ok, _} = Tasks.transition(ctx.alice_scope, bos2.ident, "done")
      assert run_status(ctx.deferred) == :queued

      assert List.last(Repo.get!(Run, ctx.deferred.id).triggers)["prerequisites"] ==
               [ctx.bos1.ident, bos2.ident]
    end

    test "删掉最后一条未满足的依赖", ctx do
      {:ok, _} = Links.remove(ctx.alice_scope, ctx.web2.ident, ctx.bos1.ident, "depends_on")
      run = Repo.get!(Run, ctx.deferred.id)
      assert run.status == :queued
      assert %{"kind" => "unblocked", "prerequisites" => []} = List.last(run.triggers)

      # No prerequisite left: no line in the prompt.
      refute prompt(run) =~ "depends on are finished"
    end

    test "an epic completed by its step releases the tasks depending on the epic", ctx do
      epic = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: "epic"})
      step = task_fixture(ctx.alice_scope, ctx.project.key, %{epic: epic.ident})
      dependent = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Links.add(ctx.alice_scope, dependent.ident, epic.ident, "depends_on")
      {:ok, _} = assign(ctx, dependent)
      [deferred] = runs_in(dependent, :deferred)

      {:ok, _} = Tasks.transition(ctx.alice_scope, step.ident, "in_progress")
      assert run_status(deferred) == :deferred

      {:ok, _} = Tasks.transition(ctx.alice_scope, step.ident, "done")
      assert Repo.reload!(epic).status == :done
      assert run_status(deferred) == :queued
    end

    test "a deferred run not waiting for dependencies is left alone", ctx do
      other = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Links.add(ctx.alice_scope, other.ident, ctx.bos1.ident, "depends_on")
      autopilot = run_with!(ctx, other, :deferred, ["autopilot"])

      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "done")

      assert run_status(ctx.deferred) == :queued

      assert %Run{status: :deferred, triggers: [%{"kind" => "autopilot"}]} =
               Repo.get!(Run, autopilot.id)
    end

    test "the prerequisite's own run still active: stays deferred", ctx do
      run_fixture(ctx.agent, %{task_id: ctx.bos1.id, status: :running})
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "done")
      assert run_status(ctx.deferred) == :deferred
    end
  end
end
