defmodule Helmsman.Tasks.AutoReopenTest do
  # add-continuation-triggers 1.7: the system reopens a verified task
  # (decision 11).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Runs, Tasks, Tx}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.{Outcome, Run}
  alias Helmsman.Tasks.{Task, TaskEvent}

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
    cancel_queued(task)

    for to <- [:in_progress, :done, :verified],
        do: {:ok, _} = Tasks.transition(ctx.alice_scope, task.ident, to)

    Map.merge(ctx, %{task: Repo.reload!(task), verification: latest_verification(task)})
  end

  defp cancel_queued(task),
    do:
      Tx.run(fn ->
        {:ok, Runs.cancel_pending(from(r in Run, where: r.task_id == ^task.id), :obsolete)}
      end)

  defp latest_verification(task),
    do:
      Repo.one!(
        from(e in TaskEvent,
          where: e.task_id == ^task.id and e.to_status == :verified,
          select: max(e.id)
        )
      )

  defp reopen(ctx, attrs \\ %{}) do
    Tasks.auto_reopen(
      ctx.task.id,
      Map.merge(
        %{
          verification_event_id: ctx.verification,
          reason: :ci_failed,
          content: "test (ubuntu) failed"
        },
        attrs
      )
    )
  end

  defp counts(task) do
    {Repo.aggregate(from(f in Entry, where: f.task_id == ^task.id), :count),
     Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^task.id), :count)}
  end

  test "CI failed (scenario)", ctx do
    assert {:ok, %{task: detail, dispatch: dispatch}} = reopen(ctx)
    assert detail.status == "in_progress"

    task = Repo.get!(Task, ctx.task.id)
    assert task.status == :in_progress

    [review] = Repo.all(from(f in Entry, where: f.task_id == ^task.id))
    assert review.kind == :review
    assert review.content == "test (ubuntu) failed"
    assert Repo.get!(Helmsman.Actors.Actor, review.author_id).kind == :system

    last =
      Repo.one!(
        from(e in TaskEvent, where: e.task_id == ^task.id, order_by: [desc: e.id], limit: 1)
      )

    assert %TaskEvent{from_status: :verified, to_status: :in_progress, auto: true} = last
    assert last.auto_reason == :ci_failed
    assert last.feedback_id == review.id
    assert last.actor_id == review.author_id

    assert [%Outcome{agent: "keel/dev", trigger: :reopen, result: :queued, run_id: id}] =
             dispatch

    run = Repo.get!(Run, id)
    assert run.root_initiator_user_id == ctx.alice.id

    assert [%{"kind" => "reopen", "reason" => "ci_failed", "from" => "verified"} = trigger] =
             run.triggers

    assert trigger["feedback_id"] == review.id
    assert trigger["by_actor_id"] == review.author_id
  end

  test "merge conflict: the run's main trigger carries the reason", ctx do
    assert {:ok, %{dispatch: [%Outcome{run_id: id}]}} = reopen(ctx, %{reason: :merge_conflict})
    run = Repo.get!(Run, id)
    assert Runs.Spec.main_trigger(run.triggers).reason == "merge_conflict"
  end

  test "the same notifications as a transition", ctx do
    Events.subscribe(Events.topic(:task, ctx.task.id))
    Events.subscribe(Events.topic(:project, ctx.task.project_id))
    assert {:ok, _} = reopen(ctx)

    ident = ctx.task.ident
    assert_receive {:feedback_added, %{kind: "review", dispatch: []}}
    assert_receive {:task_transitioned, %{ident: ^ident, event: %{auto: true, to: "in_progress"}}}
    assert_receive {:task_updated, %{id: ^ident, status: "in_progress"}}
  end

  test "a mention in the system's explanation triggers nothing", ctx do
    assert {:ok, %{dispatch: [%Outcome{trigger: :reopen}]}} =
             reopen(ctx, %{content: "cc @keel/dev"})

    assert Repo.all(from(r in Run, where: r.task_id == ^ctx.task.id and r.lane == :reply)) == []
  end

  test "already reopened (scenario): status_changed, nothing written", ctx do
    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)
    before = counts(ctx.task)
    assert reopen(ctx) == {:error, {:status_changed, :in_progress}}
    assert counts(ctx.task) == before
  end

  test "verified again since (scenario): stale, nothing written", ctx do
    for to <- [:in_progress, :done, :verified],
        do: {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, to)

    before = counts(ctx.task)
    assert reopen(ctx) == {:error, :stale}
    assert counts(ctx.task) == before
    assert Repo.get!(Task, ctx.task.id).status == :verified
  end
end
