defmodule Helmsman.Runs.LifecycleConstraintsTest do
  # add-run-lifecycle 1.1: the constraints of the lifecycle columns,
  # `run_events` and the two idempotency indexes.
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.{Run, RunEvent}
  alias Helmsman.Tasks.TaskEvent

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run = run_fixture(ctx.agent, %{task_id: task.id, status: :failed})
    Map.merge(ctx, %{task: task, run: run})
  end

  defp assert_rejected(fun) do
    error = catch_error(Repo.transact(fn -> {:ok, fun.()} end))
    assert error.__struct__ in [Postgrex.Error, Ecto.ConstraintError]
  end

  test "a new run has the lifecycle defaults", ctx do
    run = Repo.get!(Run, ctx.run.id)
    assert %Run{attempt: 1, auto_retries: 0, events_seq: 0, retry_of_id: nil} = run
    assert DateTime.diff(DateTime.utc_now(), run.not_before, :second) in 0..60
  end

  test "a run is retried by at most one row", ctx do
    run_fixture(ctx.agent, %{task_id: ctx.task.id, retry_of_id: ctx.run.id, status: :failed})

    assert_rejected(fn ->
      run_fixture(ctx.agent, %{task_id: ctx.task.id, retry_of_id: ctx.run.id, status: :failed})
    end)
  end

  test "event types and (run_id, seq) are checked", ctx do
    event = %{run_id: ctx.run.id, seq: 1, type: "text", data: %{}, at: DateTime.utc_now()}
    assert {1, _} = Repo.insert_all(RunEvent, [event])
    assert_rejected(fn -> Repo.insert_all(RunEvent, [event]) end)
    assert_rejected(fn -> Repo.insert_all(RunEvent, [%{event | seq: 2, type: "shout"}]) end)
    assert_rejected(fn -> Repo.insert_all(RunEvent, [%{event | seq: 0}]) end)
  end

  test "a run writes at most one fallback comment", ctx do
    entry = fn seq, fallback ->
      Repo.insert!(%Entry{
        workspace_id: ctx.workspace.id,
        task_id: ctx.task.id,
        seq: seq,
        thread_seq: seq,
        author_id: ctx.agent.id,
        content: "Done.",
        source_run_id: ctx.run.id,
        fallback: fallback
      })
    end

    entry.(1, true)
    entry.(2, false)
    assert_rejected(fn -> entry.(3, true) end)
  end

  test "a run claims its task automatically at most once", ctx do
    event = fn from, to, auto ->
      Repo.insert!(%TaskEvent{
        workspace_id: ctx.workspace.id,
        task_id: ctx.task.id,
        from_status: from,
        to_status: to,
        actor_id: ctx.agent.id,
        auto: auto,
        source_run_id: ctx.run.id
      })
    end

    event.(:new, :in_progress, true)
    # Other automatic entries and manual ones are not limited.
    event.(:in_progress, :done, true)
    event.(:in_progress, :done, true)
    event.(:new, :in_progress, false)
    assert_rejected(fn -> event.(:new, :in_progress, true) end)
  end

  test "the summary is at most 4 KB and the error at most 16 KB", ctx do
    update = fn changes ->
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: changes)
    end

    assert {1, _} = update.(summary: String.duplicate("a", 4096))
    assert_rejected(fn -> update.(summary: String.duplicate("a", 4097)) end)
    # Bytes, not characters.
    assert_rejected(fn -> update.(summary: String.duplicate("é", 2049)) end)
    assert {1, _} = update.(error: String.duplicate("a", 16_384))
    assert_rejected(fn -> update.(error: String.duplicate("a", 16_385)) end)
  end
end
