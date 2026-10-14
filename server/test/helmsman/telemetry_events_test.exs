defmodule Helmsman.TelemetryEventsTest do
  # The metrics' events (add-release-distribution decision 5). Telemetry
  # handlers see every process's events: not async.
  use Helmsman.DataCase, async: false

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.Report

  @base_url "http://localhost:4000"
  @claim [:helmsman, :runs, :claim]
  @finished [:helmsman, :runs, :finished]

  setup do
    ctx = dispatch_fixture()

    Repo.update_all(from(w in Helmsman.Workspaces.Workspace, where: w.id == ^ctx.workspace.id),
      set: [name: "Secret Workspace Name"]
    )

    task = task_fixture(ctx.alice_scope, ctx.project.key, %{title: "Secret task title"})
    ref = :telemetry_test.attach_event_handlers(self(), [@claim, @finished])
    on_exit(fn -> :telemetry.detach(ref) end)
    Map.merge(ctx, %{task: task, ref: ref, dctx: daemon_ctx(daemon_of(ctx.agent))})
  end

  defp refute_names(ctx, measurements, metadata) do
    text = inspect({measurements, metadata})

    for name <- ["Secret Workspace Name", ctx.workspace.slug, "Secret task title", ctx.agent.name] do
      refute text =~ name
    end

    refute text =~ ctx.alice.email
  end

  test "claiming emits one claim event with the wait, nothing that names anything", ctx do
    run = run_fixture(ctx.agent, %{task_id: ctx.task.id})
    ref = ctx.ref

    assert {:ok, [_spec]} = Runs.claim(ctx.dctx, @base_url)

    assert_receive {@claim, ^ref, %{wait_ms: wait_ms} = measurements, metadata}
    assert is_integer(wait_ms) and wait_ms >= 0
    claimed = Repo.get!(Run, run.id)
    assert wait_ms <= DateTime.diff(claimed.claimed_at, claimed.inserted_at, :millisecond) + 1
    refute_names(ctx, measurements, metadata)
    refute_receive {@claim, ^ref, _, _}
  end

  test "ending a run emits one finished event with status and failure reason", ctx do
    run = run_fixture(ctx.agent, %{task_id: ctx.task.id})
    ref = ctx.ref
    {:ok, [_spec]} = Runs.claim(ctx.dctx, @base_url)
    assert_receive {@claim, ^ref, _, _}
    {:ok, :proceed} = Runs.starting(ctx.dctx, run.id)

    {:ok, report} = Report.Finished.new(%{run_id: run.id, status: :succeeded})
    :ok = Runs.finish(ctx.dctx, report)

    assert_receive {@finished, ^ref, %{count: 1} = measurements, metadata}
    assert metadata == %{status: :succeeded, failure_reason: nil}
    refute_names(ctx, measurements, metadata)
    refute_receive {@finished, ^ref, _, _}
  end

  test "a failed run carries its failure reason", ctx do
    run = run_fixture(ctx.agent, %{task_id: ctx.task.id})
    ref = ctx.ref
    {:ok, [_spec]} = Runs.claim(ctx.dctx, @base_url)
    {:ok, :proceed} = Runs.starting(ctx.dctx, run.id)

    {:ok, report} =
      Report.Finished.new(%{run_id: run.id, status: :failed, failure_reason: :cli_error})

    :ok = Runs.finish(ctx.dctx, report)

    assert_receive {@finished, ^ref, %{count: 1}, %{status: :failed, failure_reason: :cli_error}}
    refute_receive {@finished, ^ref, _, _}
  end

  test "cancelling a queued run emits a finished event too", ctx do
    run = run_fixture(ctx.agent, %{task_id: ctx.task.id})
    ref = ctx.ref

    assert {:ok, _} = Runs.cancel(ctx.alice_scope, run.id)

    assert_receive {@finished, ^ref, %{count: 1}, %{status: :cancelled}}
  end

  test "the pollers count pending runs and online daemons", ctx do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:helmsman, :runs, :queued],
        [:helmsman, :daemons, :online]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)
    run_fixture(ctx.agent, %{task_id: ctx.task.id})
    run_fixture(ctx.agent, %{status: :deferred})

    HelmsmanWeb.Telemetry.measure_runs()
    HelmsmanWeb.Telemetry.measure_daemons()

    assert_receive {[:helmsman, :runs, :queued], ^ref, %{count: queued}, %{status: :queued}}
    assert_receive {[:helmsman, :runs, :queued], ^ref, %{count: deferred}, %{status: :deferred}}
    assert queued >= 1 and deferred >= 1
    assert_receive {[:helmsman, :daemons, :online], ^ref, %{count: online}, %{}}
    assert online >= 1
  end
end
