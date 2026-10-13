defmodule Helmsman.Autopilots.SettleTest do
  # add-autopilots 4.1: settling and disabling after failures (decision 8;
  # specs/autopilot-execution "结算", "连续失败自动停用").
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentsFixtures
  import Helmsman.AutopilotsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Autopilots, Tasks}
  alias Helmsman.Autopilots.Record
  alias Helmsman.Runs.Run
  alias Helmsman.Runs.Workers.Retry, as: RetryJob
  alias Helmsman.Tasks.Task

  setup do
    ctx = autopilots_fixture()
    view = autopilot_fixture(ctx.alice_scope)
    Map.put(ctx, :view, view)
  end

  defp started(ctx) do
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, ctx.view.id)
    assert record.status == :started
    record
  end

  defp set_task(record, changes),
    do: Repo.update_all(from(t in Task, where: t.id == ^record.task_id), set: changes)

  defp set_run(run_id, changes),
    do: Repo.update_all(from(r in Run, where: r.id == ^run_id), set: changes)

  defp settle(ctx) do
    {:ok, _} = Autopilots.settle(ctx.view.id)
    :ok
  end

  defp fail_run!(record, reason \\ :cli_error) do
    set_run(record.run_id,
      status: :failed,
      failure_reason: reason,
      finished_at: DateTime.utc_now()
    )
  end

  test "done counts as success; a later rejection changes nothing; the next trigger runs", ctx do
    r = started(ctx)
    set_task(r, status: :done)
    settle(ctx)
    assert %{status: :succeeded, finished_at: %DateTime{}} = Repo.reload!(r)

    set_task(r, status: :in_progress)
    settle(ctx)
    assert %{status: :succeeded} = Repo.reload!(r)
    assert %{status: :started} = started(ctx)
  end

  test "waiting for an answer: still started", ctx do
    r = started(ctx)
    set_run(r.run_id, status: :succeeded, finished_at: DateTime.utc_now())
    set_task(r, status: :in_progress)
    settle(ctx)
    assert %{status: :started} = Repo.reload!(r)
  end

  test "a failure that will be retried keeps it started; the last failure fails it", ctx do
    r = started(ctx)
    fail_run!(r, :provider_network)
    {:ok, _} = Oban.insert(RetryJob.new(%{run_id: r.run_id}, schedule_in: 30))
    settle(ctx)
    assert %{status: :started} = Repo.reload!(r)

    # The retry ran and failed for good.
    Repo.delete_all(Oban.Job)
    retry = run_fixture(ctx.agent, %{task_id: r.task_id, retry_of_id: r.run_id})

    set_run(retry.id,
      status: :failed,
      failure_reason: :provider_network,
      auto_retries: 3,
      finished_at: DateTime.utc_now()
    )

    settle(ctx)

    assert %{status: :failed, reason: "run_failed", result: "provider_network" <> _} =
             Repo.reload!(r)
  end

  test "reassigned to a person: cancelled / reassigned, the count unchanged", ctx do
    r = started(ctx)

    {:ok, _} =
      Tasks.update(ctx.alice_scope, Repo.get!(Task, r.task_id).ident, %{
        assignee: ctx.bob_scope.actor.name
      })

    settle(ctx)
    assert %{status: :cancelled, reason: "reassigned"} = Repo.reload!(r)
    assert autopilot_row(ctx.view).consecutive_failures == 0
  end

  test "the fifth failure disables it", ctx do
    Repo.update_all(from(a in Autopilots.Autopilot, where: a.id == ^ctx.view.id),
      set: [consecutive_failures: 4]
    )

    r = started(ctx)
    fail_run!(r)
    settle(ctx)
    assert %{status: :failed, reason: "run_failed"} = Repo.reload!(r)

    assert %{enabled: false, disabled_reason: :consecutive_failures, consecutive_failures: 5} =
             autopilot_row(ctx.view)
  end

  test "skips and stops do not break the count", ctx do
    Repo.update_all(from(a in Autopilots.Autopilot, where: a.id == ^ctx.view.id),
      set: [consecutive_failures: 3]
    )

    # Skipped (overlap) while one is in progress, then a person stops it.
    r = started(ctx)
    {:ok, skipped} = Autopilots.run_now(ctx.alice_scope, ctx.view.id)
    assert skipped.status == :skipped

    set_run(r.run_id,
      status: :cancelled,
      failure_reason: :obsolete,
      cancel_requested_by_id: ctx.alice_scope.actor.id,
      finished_at: DateTime.utc_now()
    )

    settle(ctx)
    assert %{status: :cancelled, reason: "stopped"} = Repo.reload!(r)

    r2 = started(ctx)
    fail_run!(r2)
    settle(ctx)
    assert %{consecutive_failures: 4, enabled: true} = autopilot_row(ctx.view)
  end

  test "settling twice: the same result, counted once", ctx do
    r = started(ctx)
    fail_run!(r)
    settle(ctx)
    settle(ctx)
    assert %{status: :failed} = Repo.reload!(r)
    assert autopilot_row(ctx.view).consecutive_failures == 1
  end

  describe "an execution in progress keeps its own configuration" do
    setup ctx do
      managed_agent_fixture(ctx.alice_scope, %{
        name: "keel/other",
        runtime_id: profile(ctx.agent).runtime_id
      })

      other_project = Helmsman.ProjectsFixtures.project_fixture(ctx.alice_scope, %{key: "KEEL"})
      Map.put(ctx, :other_project, other_project)
    end

    for change <- [:mode, :agent, :project] do
      @change change
      test "after changing #{change}, done is still a success", ctx do
        r = started(ctx)
        set_run(r.run_id, status: :succeeded, finished_at: DateTime.utc_now())

        attrs =
          case @change do
            :mode -> %{mode: "run_only"}
            :agent -> %{agent: "keel/other"}
            :project -> %{project: "KEEL"}
          end

        {:ok, _} = Autopilots.update(ctx.alice_scope, ctx.view.id, attrs)
        settle(ctx)
        assert %{status: :started} = Repo.reload!(r)

        set_task(r, status: :done)
        settle(ctx)
        assert %{status: :succeeded} = Repo.reload!(r)
      end
    end
  end

  # Task status × assignee × last run → the record's status and reason
  # (nil: still started).
  @table [
    {:done, :target, nil, {:succeeded, nil}},
    {:verified, :target, nil, {:succeeded, nil}},
    {:rejected, :target, nil, {:failed, "task_rejected"}},
    {:cancelled, :target, nil, {:cancelled, "task_cancelled"}},
    {:in_progress, :other, nil, {:cancelled, "reassigned"}},
    {:in_progress, :target, :succeeded, nil},
    {:in_progress, :target, :retry_pending, nil},
    {:in_progress, :target, :failed_final, {:failed, "run_failed"}},
    {:in_progress, :target, :stopped_by_person, {:cancelled, "stopped"}},
    {:in_progress, :target, :cancelled_by_system, {:failed, "run_failed"}},
    {:in_progress, :target, :running, nil},
    {:new, :target, :none, nil}
  ]

  for {{status, assignee, last, expected}, i} <- Enum.with_index(@table) do
    @row {status, assignee, last, expected}
    test "table row #{i}: #{status} × #{assignee} × #{last}", ctx do
      {status, assignee, last, expected} = @row
      r = started(ctx)
      set_task(r, status: status)
      assign!(r, assignee, ctx)
      last_run!(r, last, ctx)
      settle(ctx)
      check!(Repo.reload!(r), expected)
    end
  end

  defp assign!(_r, :target, _ctx), do: :ok
  defp assign!(r, :other, ctx), do: set_task(r, assignee_id: ctx.bob_scope.actor.id)

  defp last_run!(_r, nil, _ctx), do: :ok
  defp last_run!(r, :none, _ctx), do: Repo.delete_all(from(x in Run, where: x.id == ^r.run_id))

  defp last_run!(r, :succeeded, _ctx),
    do: set_run(r.run_id, status: :succeeded, finished_at: DateTime.utc_now())

  defp last_run!(r, :running, _ctx), do: set_run(r.run_id, status: :running)

  defp last_run!(r, :retry_pending, _ctx) do
    set_run(r.run_id, status: :failed, failure_reason: :timeout, finished_at: DateTime.utc_now())
    {:ok, _} = Oban.insert(RetryJob.new(%{run_id: r.run_id}))
  end

  defp last_run!(r, :failed_final, _ctx),
    do:
      set_run(r.run_id,
        status: :failed,
        failure_reason: :cli_error,
        finished_at: DateTime.utc_now()
      )

  defp last_run!(r, :stopped_by_person, ctx),
    do:
      set_run(r.run_id,
        status: :cancelled,
        failure_reason: :obsolete,
        cancel_requested_by_id: ctx.alice_scope.actor.id,
        finished_at: DateTime.utc_now()
      )

  defp last_run!(r, :cancelled_by_system, _ctx),
    do:
      set_run(r.run_id,
        status: :cancelled,
        failure_reason: :unauthorized,
        finished_at: DateTime.utc_now()
      )

  defp check!(record, nil), do: assert(record.status == :started)

  defp check!(record, {status, reason}),
    do: assert({record.status, record.reason} == {status, reason})

  test "a record whose task was deleted: cancelled / task_deleted", ctx do
    r = started(ctx)
    Repo.update_all(from(x in Record, where: x.id == ^r.id), set: [task_id: nil])
    settle(ctx)
    assert %{status: :cancelled, reason: "task_deleted"} = Repo.reload!(r)
  end
end
