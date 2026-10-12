defmodule Helmsman.Runs.RetryTest do
  # add-run-lifecycle 4.2: automatic and manual retries (decisions 14, 25).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, Runs, Runtimes, Tasks}
  alias Helmsman.Runs.Run
  alias Helmsman.Runs.Workers.Retry
  alias HelmsmanProtocol.Report

  setup do
    ctx = dispatch_fixture(%{access: "workspace"})
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    daemon = daemon_of(ctx.agent)

    Map.merge(ctx, %{
      task: task,
      daemon: daemon,
      runtime_id: profile(ctx.agent).runtime_id,
      assign: trigger("assign", ctx.workspace, ctx.alice, ctx.agent)
    })
  end

  defp failed(ctx, reason, attrs \\ %{}) do
    run_fixture(
      ctx.agent,
      Map.merge(
        %{
          task_id: ctx.task.id,
          status: :failed,
          failure_reason: reason,
          triggers: [ctx.assign],
          daemon_id: ctx.daemon.id,
          finished_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp perform(run), do: perform_job(Retry, %{run_id: run.id})
  defp retry_of(run), do: Repo.get_by(Run, retry_of_id: run.id)

  defp queued(ctx),
    do: Repo.all(from(r in Run, where: r.task_id == ^ctx.task.id and r.status == :queued))

  # The daemon reports the run's failure; returns the retry job's result.
  defp fail_reported(ctx, run, reason) do
    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [status: :running, daemon_id: ctx.daemon.id, claimed_at: DateTime.utc_now()]
    )

    {:ok, report} =
      Report.Finished.new(%{run_id: run.id, status: :failed, failure_reason: reason})

    :ok = Runs.finish(daemon_ctx(ctx.daemon), report)
  end

  test "three timeouts in a row: two retries (scenario)", ctx do
    first = run_fixture(ctx.agent, %{task_id: ctx.task.id, triggers: [ctx.assign]})

    second =
      Enum.reduce(1..2, first, fn n, run ->
        fail_reported(ctx, run, :timeout)
        assert_enqueued(worker: Retry, args: %{run_id: run.id})
        assert :ok = perform(run)
        retry = retry_of(run)
        assert %Run{status: :queued, attempt: attempt, auto_retries: ^n} = retry
        assert attempt == n + 1
        retry
      end)

    fail_reported(ctx, second, :timeout)
    refute_enqueued(worker: Retry, args: %{run_id: second.id})
    assert :ok = perform(second)
    refute retry_of(second)
  end

  test "limits and delays per reason; lease_expired is not counted", ctx do
    for {reason, limit, delay} <- [
          {:runtime_offline, 2, 0},
          {:daemon_restart, 2, 0},
          {:stalled, 2, 0},
          {:push_conflict, 2, 0},
          {:push_failed, 2, 0},
          {:provider_network, 3, 30},
          {:provider_rate_limit, 1, 300}
        ] do
      assert Runs.Retry.automatic?(%Run{
               status: :failed,
               failure_reason: reason,
               auto_retries: limit - 1
             })

      refute Runs.Retry.automatic?(%Run{
               status: :failed,
               failure_reason: reason,
               auto_retries: limit
             })

      run = failed(ctx, reason)
      assert :ok = perform(run)
      retry = retry_of(run)
      assert DateTime.diff(retry.not_before, DateTime.utc_now(), :second) in (delay - 5)..delay
      Repo.update_all(from(r in Run, where: r.id == ^retry.id), set: [status: :cancelled])
    end

    lease = failed(ctx, :lease_expired, %{attempt: 3, auto_retries: 2})
    assert Runs.Retry.automatic?(lease)
    assert :ok = perform(lease)
    assert %Run{attempt: 3, auto_retries: 2} = retry_of(lease)
  end

  test "other reasons are not retried", ctx do
    for reason <- [
          :provider_auth,
          :provider_quota,
          :cli_missing,
          :workspace_prepare,
          :obsolete,
          :unauthorized,
          :context_overflow,
          :cli_error,
          :unknown
        ] do
      run = failed(ctx, reason)
      refute Runs.Retry.automatic?(run)
      assert :ok = perform(run)
      refute retry_of(run)
    end
  end

  test "a retry keeps the source and triggers, adds its marker, runs on the current runtime",
       ctx do
    retry_marker = %{"kind" => "retry", "retry_of" => 1, "auto" => true}
    run = failed(ctx, :timeout, %{triggers: [ctx.assign, retry_marker], priority: 3})

    {daemon, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
    runtime = runtime_fixture(ctx.workspace, daemon)
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{runtime_id: runtime.id})

    assert :ok = perform(run)
    retry = retry_of(run)
    assert retry.runtime_id == runtime.id
    assert retry.root_initiator_user_id == ctx.alice.id
    assert retry.priority == 3
    refute retry_marker in retry.triggers
    assert [assign, %{"kind" => "retry", "retry_of" => id, "auto" => true}] = retry.triggers
    assert assign == ctx.assign
    assert id == run.id
  end

  test "a retry merges into the queued run of the same task, agent and lane", ctx do
    existing = run_fixture(ctx.agent, %{task_id: ctx.task.id, triggers: [ctx.assign]})
    run = failed(ctx, :timeout)

    assert :ok = perform(run)
    assert [merged] = queued(ctx)
    assert merged.id == existing.id
    assert Enum.any?(merged.triggers, &(&1["kind"] == "retry" and &1["retry_of"] == run.id))

    # Again: nothing more.
    assert :ok = perform(run)
    assert [again] = queued(ctx)
    assert length(again.triggers) == length(merged.triggers)
  end

  test "performed twice: one retry", ctx do
    run = failed(ctx, :timeout)
    assert :ok = perform(run)
    assert :ok = perform(run)
    assert [_one] = queued(ctx)
  end

  test "no retry when the agent or runtime cannot run it or the task is closed", ctx do
    cases = [
      fn -> Agents.disable(ctx.alice_scope, "keel/dev") end,
      fn -> Agents.archive(ctx.alice_scope, "keel/dev") end,
      fn -> Agents.update(ctx.alice_scope, "keel/dev", %{runtime_id: nil}) end,
      fn -> Runtimes.disable(ctx.alice_scope, ctx.runtime_id) end,
      fn -> Tasks.transition(ctx.alice_scope, ctx.task.ident, :cancelled) end
    ]

    for change <- cases do
      run = failed(ctx, :timeout)

      Helmsman.Tx.run(fn ->
        {:ok, _} = change.()
        assert :ok = perform(run)
        refute retry_of(run)
        assert queued(ctx) == []
        {:error, :rollback}
      end)
    end
  end

  describe "manual" do
    test "alice retries a provider_auth failure (scenario)", ctx do
      {bob, _} = member_scope_fixture(ctx.workspace)
      run = failed(ctx, :provider_auth, %{root_initiator_user_id: bob.id, auto_retries: 2})

      assert {:ok, %{status: "queued", triggers: triggers}} = Runs.retry(ctx.alice_scope, run.id)
      assert %{kind: "retry", auto: false, retry_of: id, by: %{name: _}} = List.last(triggers)
      assert id == run.id

      retry = retry_of(run)
      assert %Run{root_initiator_user_id: bob_id, auto_retries: 0, attempt: 2} = retry
      assert bob_id == bob.id
    end

    test "a cancelled run too; not a running one", ctx do
      cancelled = failed(ctx, nil, %{status: :cancelled})
      assert {:ok, _} = Runs.retry(ctx.alice_scope, cancelled.id)

      running = run_fixture(ctx.agent, %{status: :running})
      assert Runs.retry(ctx.alice_scope, running.id) == {:error, :not_ended}
    end

    test "the retry still queued is returned; an ended one is refused", ctx do
      run = failed(ctx, :provider_auth)
      assert {:ok, %{id: id}} = Runs.retry(ctx.alice_scope, run.id)
      assert {:ok, %{id: ^id}} = Runs.retry(ctx.alice_scope, run.id)

      Repo.update_all(from(r in Run, where: r.id == ^id), set: [status: :failed])
      assert Runs.retry(ctx.alice_scope, run.id) == {:error, {:already_retried, id}}
    end

    test "errors: closed task, disabled agent, unrelated member", ctx do
      run = failed(ctx, :provider_auth)
      {_carol, carol_scope} = member_scope_fixture(ctx.workspace)
      assert Runs.retry(carol_scope, run.id) == {:error, :forbidden}

      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :cancelled)
      assert Runs.retry(ctx.alice_scope, run.id) == {:error, :task_closed}

      other = run_fixture(ctx.agent, %{status: :failed, failure_reason: :unknown})
      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")
      assert Runs.retry(ctx.alice_scope, other.id) == {:error, :agent_disabled}
    end
  end
end

defmodule Helmsman.Runs.RetryInterleavingTest do
  # add-run-lifecycle 4.2: the automatic retry and unbinding / rebinding the
  # agent, in both orders (scenarios); never a queued run on a runtime the
  # agent is not bound to.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, CommittedData, LockHarness, Repo}
  alias Helmsman.Runs.Retry, as: Requeue
  alias Helmsman.Runs.Run

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture()
        task = task_fixture(ctx.alice_scope, ctx.project.key)
        {daemon, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
        r2 = runtime_fixture(ctx.workspace, daemon)

        run =
          run_fixture(ctx.agent, %{
            task_id: task.id,
            status: :failed,
            failure_reason: :timeout,
            finished_at: DateTime.utc_now()
          })

        Map.merge(ctx, %{task: task, run: run, r1: profile(ctx.agent).runtime_id, r2: r2.id})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  defp retry(ctx), do: fn -> Requeue.perform(ctx.run.id) end

  defp bind(ctx, runtime_id),
    do: fn -> Agents.update(ctx.alice_scope, "keel/dev", %{runtime_id: runtime_id}) end

  defp queued(ctx) do
    CommittedData.unboxed(fn ->
      Repo.all(
        from(r in Run,
          where: r.task_id == ^ctx.task.id and r.status == :queued,
          select: r.runtime_id
        )
      )
    end)
  end

  test "unbinding first: no retry (scenario)", ctx do
    assert {{:ok, _}, {:ok, :skipped}} =
             LockHarness.interleave(bind(ctx, nil), :commit, retry(ctx))

    assert queued(ctx) == []
  end

  test "the retry first: unbinding then cancels it", ctx do
    assert {{:ok, :retried}, {:ok, _}} =
             LockHarness.interleave(retry(ctx), :retry_locked, bind(ctx, nil))

    assert queued(ctx) == []
  end

  test "the retry first: rebinding moves it to R2 (scenario)", ctx do
    assert {{:ok, :retried}, {:ok, _}} =
             LockHarness.interleave(retry(ctx), :retry_locked, bind(ctx, ctx.r2))

    assert queued(ctx) == [ctx.r2]
  end

  test "rebinding first: the retry goes to R2", ctx do
    assert {{:ok, _}, {:ok, :retried}} =
             LockHarness.interleave(bind(ctx, ctx.r2), :commit, retry(ctx))

    assert queued(ctx) == [ctx.r2]
  end

  describe "concurrent retries of a run without a task (code review 1)" do
    # No task row to serialize them: the original run's row does.
    setup ctx do
      failed =
        CommittedData.unboxed(fn ->
          run_fixture(ctx.agent, %{
            status: :failed,
            failure_reason: :timeout,
            finished_at: DateTime.utc_now()
          })
        end)

      %{failed: failed}
    end

    defp manual(ctx), do: fn -> Helmsman.Runs.retry(ctx.alice_scope, ctx.failed.id) end
    defp automatic(ctx), do: fn -> Requeue.perform(ctx.failed.id) end

    defp retries(ctx) do
      CommittedData.unboxed(fn ->
        Repo.all(from(r in Run, where: r.retry_of_id == ^ctx.failed.id, select: r.id))
      end)
    end

    test "manual and manual: one retry, both get it", ctx do
      assert {{:ok, %{id: id}}, {:ok, %{id: id}}} =
               LockHarness.interleave(manual(ctx), :retry_checking, manual(ctx))

      assert retries(ctx) == [id]
    end

    test "automatic first, then manual: the manual one gets that retry", ctx do
      assert {{:ok, :retried}, {:ok, %{id: id}}} =
               LockHarness.interleave(automatic(ctx), :retry_checking, manual(ctx))

      assert retries(ctx) == [id]
    end

    test "manual first, then automatic: the automatic one does nothing", ctx do
      assert {{:ok, %{id: id}}, {:ok, :skipped}} =
               LockHarness.interleave(manual(ctx), :retry_checking, automatic(ctx))

      assert retries(ctx) == [id]
    end
  end
end
