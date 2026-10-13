defmodule Helmsman.Links.EpicNotifyTest do
  # `add-epics` decision 11, `add-task-links` decision 9: an epic's
  # automatic transitions notify the tasks depending on it, and only that.
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Links, Tasks}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  setup do
    ctx = dispatch_fixture()
    scope = ctx.alice_scope
    project_fixture(scope, key: "BOS")
    project_fixture(scope, key: "WEB")
    epic = task_fixture(scope, "BOS", %{kind: "epic"})
    step = task_fixture(scope, "BOS", %{epic: epic.ident})
    # The dependent is assigned to a managed agent: a notification must not
    # start a run for it.
    dependent = task_fixture(scope, "WEB", %{assignee: "keel/dev", start: false})
    {:ok, _} = Links.add(scope, dependent.ident, epic.ident, "depends_on")
    Map.merge(ctx, %{scope: scope, epic: epic, step: step, dependent: dependent})
  end

  defp subscribe(%Task{} = task) do
    Events.subscribe(Events.topic(:task, task.id))
    Events.subscribe(Events.topic(:project, task.project_id))
  end

  defp status(task), do: Repo.get!(Task, task.id).status

  defp counts do
    %{rows: [[jobs]]} =
      Repo.query!("SELECT count(*) FROM oban_jobs WHERE worker LIKE '%ReconcilePR%'")

    {Repo.aggregate(Run, :count), jobs}
  end

  test "an epic completed by its last step notifies its dependents", ctx do
    %{scope: scope, epic: epic, step: step, dependent: dependent} = ctx
    {:ok, _} = Tasks.transition(scope, step.ident, "in_progress")
    before = counts()
    subscribe(dependent)
    ident = dependent.ident

    {:ok, _} = Tasks.transition(scope, step.ident, "done")

    assert status(epic) == :done
    assert_receive {:task_updated, %{id: ^ident, blocked: false}}
    assert_receive {:links_changed, ^ident}
    assert counts() == before
    assert {_runs, 0} = counts()
  end

  test "a new step on a done epic reopens it and blocks its dependents again", ctx do
    %{scope: scope, epic: epic, step: step, dependent: dependent} = ctx
    {:ok, _} = Tasks.transition(scope, step.ident, "in_progress")
    {:ok, _} = Tasks.transition(scope, step.ident, "done")
    assert status(epic) == :done
    before = counts()
    subscribe(dependent)
    ident = dependent.ident

    task_fixture(scope, "BOS", %{epic: epic.ident})

    assert status(epic) == :in_progress
    {:ok, task} = Tasks.get(scope, ident)
    assert Tasks.summary(task).blocked
    assert_receive {:task_updated, %{id: ^ident, blocked: true}}
    assert_receive {:links_changed, ^ident}
    assert counts() == before
    assert {_runs, 0} = counts()
  end

  test "an epic recomputed without a status change notifies no dependent", ctx do
    %{scope: scope, epic: epic, step: step, dependent: dependent} = ctx
    subscribe(dependent)

    {:ok, _} = Tasks.transition(scope, step.ident, "in_progress")

    assert status(epic) == :new
    refute_receive {:links_changed, _}
    refute_receive {:task_updated, %{id: "WEB-" <> _}}
  end
end
