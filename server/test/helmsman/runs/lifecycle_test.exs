defmodule Helmsman.Runs.LifecycleTest do
  # add-run-lifecycle 3.1–3.3: starting, started, events and the end, as
  # reported by the daemon that claimed the run.
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Runs, Tasks}
  alias Helmsman.Runs.{Run, RunEvent, RunTokens}
  alias Helmsman.Runs.Workers.{Retry, SideEffect}
  alias HelmsmanProtocol.{Event, Report}

  setup do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
    [run] = runs_of(task.id)

    {1, [run]} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id, select: r),
        set: [status: :claimed, daemon_id: daemon.id, claimed_at: DateTime.utc_now()]
      )

    {:ok, token} = RunTokens.issue(run)

    Map.merge(ctx, %{daemon: daemon, dctx: daemon_ctx(daemon), task: task, run: run, token: token})
  end

  defp reload(run), do: Repo.get!(Run, run.id)

  defp set(run, changes),
    do: Repo.update_all(from(r in Run, where: r.id == ^run.id), set: changes)

  defp event(seq, type \\ :text, data \\ %{text: "hello"}) do
    {:ok, event} =
      Event.new(%{seq: seq, type: type, data: data, at: DateTime.utc_now()})

    event
  end

  defp events(range), do: Enum.map(range, &event/1)

  defp finished(run, attrs \\ %{}) do
    {:ok, report} =
      Report.Finished.new(Map.merge(%{run_id: run.id, status: :succeeded}, attrs))

    report
  end

  describe "starting" do
    test "a valid run starts: running, started_at, an auto_claim job", ctx do
      Events.subscribe(Events.topic(:run, ctx.run.id))
      assert Runs.starting(ctx.dctx, ctx.run.id) == {:ok, :proceed}

      assert %Run{status: :running, started_at: %DateTime{}} = reload(ctx.run)
      assert_enqueued(worker: SideEffect, args: %{run_id: ctx.run.id, kind: "auto_claim"})
      assert_receive {:run_updated, %{status: "running"}}
    end

    test "a task cancelled while preparing: abort, failed obsolete (scenario)", ctx do
      assert {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :cancelled)
      assert Runs.starting(ctx.dctx, ctx.run.id) == {:ok, {:abort, "obsolete"}}
      assert %Run{status: :failed, failure_reason: :obsolete, started_at: nil} = reload(ctx.run)
      assert RunTokens.authenticate(ctx.token) == {:error, :unauthorized}
      refute_enqueued(worker: SideEffect)
      refute_enqueued(worker: Retry)

      # The reply was lost: the same decision again (scenario).
      assert Runs.starting(ctx.dctx, ctx.run.id) == {:ok, {:abort, "obsolete"}}
      assert reload(ctx.run).status == :failed
    end

    test "a run stopped after it was claimed: abort, cancelled; again the same", ctx do
      set(ctx.run, status: :cancelling)
      assert Runs.starting(ctx.dctx, ctx.run.id) == {:ok, {:abort, "cancelled"}}
      assert reload(ctx.run).status == :cancelled
      assert Runs.starting(ctx.dctx, ctx.run.id) == {:ok, {:abort, "cancelled"}}
    end

    test "a cancelling run that already started is cancelled on a resent starting", ctx do
      assert Runs.starting(ctx.dctx, ctx.run.id) == {:ok, :proceed}
      set(ctx.run, status: :cancelling)
      assert Runs.starting(ctx.dctx, ctx.run.id) == {:ok, {:abort, "cancelled"}}
      assert reload(ctx.run).status == :cancelled
    end

    test "the proceed reply was lost: proceed again, nothing changes (scenario)", ctx do
      assert Runs.starting(ctx.dctx, ctx.run.id) == {:ok, :proceed}
      started_at = reload(ctx.run).started_at
      Events.subscribe(Events.topic(:run, ctx.run.id))

      assert Runs.starting(ctx.dctx, ctx.run.id) == {:ok, :proceed}
      assert reload(ctx.run).started_at == started_at
      assert [_one] = all_enqueued(worker: SideEffect)
      refute_receive {:run_updated, _}
    end

    test "a starting that arrives after the lease expired: abort lease_expired", ctx do
      set(ctx.run,
        status: :failed,
        failure_reason: :lease_expired,
        finished_at: DateTime.utc_now()
      )

      assert Runs.starting(ctx.dctx, ctx.run.id) == {:ok, {:abort, "lease_expired"}}
    end

    test "another daemon, another epoch, a finished started run", ctx do
      {other, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
      assert Runs.starting(daemon_ctx(other), ctx.run.id) == {:error, :not_found}

      stale = %{ctx.dctx | auth_epoch: ctx.dctx.auth_epoch + 1}
      assert Runs.starting(stale, ctx.run.id) == {:error, :reauthorized}
      assert reload(ctx.run).status == :claimed

      set(ctx.run, status: :succeeded, started_at: DateTime.utc_now())
      assert Runs.starting(ctx.dctx, ctx.run.id) == {:error, :wrong_state}
    end
  end

  describe "started" do
    test "records the session; only running or cancelling", ctx do
      started = %Report.Started{run_id: ctx.run.id, session_id: "s-9"}
      assert Runs.started(ctx.dctx, started) == {:error, :wrong_state}

      {:ok, :proceed} = Runs.starting(ctx.dctx, ctx.run.id)
      assert Runs.started(ctx.dctx, started) == :ok
      assert Runs.started(ctx.dctx, %{started | session_id: nil}) == :ok
      assert reload(ctx.run).session_id == "s-9"
    end
  end

  describe "events" do
    setup ctx do
      {:ok, :proceed} = Runs.starting(ctx.dctx, ctx.run.id)
      Events.subscribe(Events.topic(:run, ctx.run.id))
      :ok
    end

    test "a resent batch: duplicates ignored, acked to the last (scenario)", ctx do
      assert Runs.append_events(ctx.dctx, ctx.run.id, events(1..3)) == {:ok, 3}
      assert_receive {:run_events, _, [%{seq: 1}, %{seq: 2}, %{seq: 3}]}

      assert Runs.append_events(ctx.dctx, ctx.run.id, events(1..5)) == {:ok, 5}

      assert_receive {:run_events, _,
                      [%{seq: 4, type: "text", data: %{"text" => "hello"}}, %{seq: 5}]}

      assert Repo.aggregate(from(e in RunEvent, where: e.run_id == ^ctx.run.id), :count) == 5
      assert %Run{events_seq: 5, last_event_at: %DateTime{}} = reload(ctx.run)

      assert Runs.append_events(ctx.dctx, ctx.run.id, events(2..3)) == {:ok, 5}
      refute_receive {:run_events, _, _}
    end

    test "a gap is invalid and saves nothing (scenario)", ctx do
      {:ok, 3} = Runs.append_events(ctx.dctx, ctx.run.id, events(1..3))

      assert Runs.append_events(ctx.dctx, ctx.run.id, events(5..6)) ==
               {:error, {:invalid_payload, :gap}}

      assert Runs.append_events(ctx.dctx, ctx.run.id, [event(4), event(6)]) ==
               {:error, {:invalid_payload, :gap}}

      assert Repo.aggregate(from(e in RunEvent, where: e.run_id == ^ctx.run.id), :count) == 3
      assert reload(ctx.run).events_seq == 3
    end

    test "a session event records the session", ctx do
      assert {:ok, 1} =
               Runs.append_events(ctx.dctx, ctx.run.id, [
                 event(1, :session, %{session_id: "s-42"})
               ])

      assert reload(ctx.run).session_id == "s-42"
    end

    test "a late report after the run failed (scenario), a claimed run", ctx do
      set(ctx.run, status: :claimed)
      assert Runs.append_events(ctx.dctx, ctx.run.id, events(1..1)) == {:error, :wrong_state}
      set(ctx.run, status: :failed, failure_reason: :runtime_offline)
      assert Runs.append_events(ctx.dctx, ctx.run.id, events(1..1)) == {:error, :wrong_state}
      assert Repo.aggregate(from(e in RunEvent, where: e.run_id == ^ctx.run.id), :count) == 0
    end
  end

  describe "finish" do
    test "succeeded (scenario): summary, token revoked, fallback job", ctx do
      {:ok, :proceed} = Runs.starting(ctx.dctx, ctx.run.id)

      usage = %{
        input_tokens: 10,
        output_tokens: 5,
        cache_read_tokens: nil,
        cache_write_tokens: nil,
        cost_usd: 0.01
      }

      report = finished(ctx.run, %{summary: "Done.", session_id: "s-1", usage: usage})
      assert Runs.finish(ctx.dctx, report) == :ok

      assert %Run{status: :succeeded, summary: "Done.", session_id: "s-1"} = run = reload(ctx.run)
      assert run.finished_at
      assert run.usage["input_tokens"] == 10
      assert RunTokens.authenticate(ctx.token) == {:error, :unauthorized}
      assert_enqueued(worker: SideEffect, args: %{run_id: ctx.run.id, kind: "fallback"})

      # The same end again is fine; another is not.
      assert Runs.finish(ctx.dctx, report) == :ok

      assert Runs.finish(
               ctx.dctx,
               finished(ctx.run, %{status: :failed, failure_reason: :unknown})
             ) ==
               {:error, :wrong_state}
    end

    test "failed while preparing (scenario): no retry for workspace_prepare", ctx do
      report = finished(ctx.run, %{status: :failed, failure_reason: :workspace_prepare})
      assert Runs.finish(ctx.dctx, report) == :ok
      assert %Run{status: :failed, failure_reason: :workspace_prepare} = reload(ctx.run)
      refute_enqueued(worker: Retry)
      refute_enqueued(worker: SideEffect)
    end

    test "a retryable failure inserts only the retry job", ctx do
      {:ok, :proceed} = Runs.starting(ctx.dctx, ctx.run.id)
      report = finished(ctx.run, %{status: :failed, failure_reason: :timeout, error: "slow"})
      assert Runs.finish(ctx.dctx, report) == :ok
      assert %Run{error: "slow"} = reload(ctx.run)
      assert_enqueued(worker: Retry, args: %{run_id: ctx.run.id})
      # Not requeued in this transaction.
      assert [_only] = runs_of(ctx.task.id)
    end

    test "a cancelling run is cancelled whatever was reported, keeping its reason", ctx do
      {:ok, :proceed} = Runs.starting(ctx.dctx, ctx.run.id)
      set(ctx.run, status: :cancelling, failure_reason: :unauthorized)
      assert Runs.finish(ctx.dctx, finished(ctx.run, %{summary: "Half."})) == :ok

      assert %Run{status: :cancelled, failure_reason: :unauthorized, summary: "Half."} =
               reload(ctx.run)

      refute_enqueued(worker: SideEffect, args: %{kind: "fallback"})
      refute_enqueued(worker: Retry)
    end

    test "another daemon's run is not found (scenario)", ctx do
      {other, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
      assert Runs.finish(daemon_ctx(other), finished(ctx.run)) == {:error, :not_found}
      assert reload(ctx.run).status == :claimed
    end
  end
end
