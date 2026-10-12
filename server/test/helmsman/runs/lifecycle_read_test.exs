defmodule Helmsman.Runs.LifecycleReadTest do
  # add-run-lifecycle 6.2: reading runs and their events, the summary and
  # its notifications (decisions 19, 20; domain request R2–R4).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Runs, Tasks}
  alias Helmsman.Runs.{Run, RunEvent}

  setup do
    ctx = dispatch_fixture(%{access: "workspace"})
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    daemon = daemon_of(ctx.agent)

    run =
      run_fixture(ctx.agent, %{
        status: :failed,
        failure_reason: :cli_error,
        error: "stack trace",
        daemon_id: daemon.id,
        events_seq: 12,
        summary: "Partial.",
        usage: %{"input_tokens" => 3},
        root_initiator_user_id: bob.id
      })

    Repo.insert_all(
      RunEvent,
      for(
        seq <- 1..12,
        do: %{
          run_id: run.id,
          seq: seq,
          type: "text",
          data: %{"text" => "#{seq}"},
          at: DateTime.utc_now()
        }
      )
    )

    Map.merge(ctx, %{
      viewer_scope: viewer_scope,
      bob: bob,
      bob_scope: bob_scope,
      daemon: daemon,
      run: run
    })
  end

  defp seqs({:ok, %{events: events}}), do: Enum.map(events, & &1.seq)

  test "the summary: lifecycle fields, the initiator, owner and retries; never the error", ctx do
    retry = run_fixture(ctx.agent, %{retry_of_id: ctx.run.id})
    marker = %{"kind" => "retry", "retry_of" => ctx.run.id, "auto" => true, "by_actor_id" => nil}
    Repo.update_all(from(r in Run, where: r.id == ^retry.id), set: [triggers: [marker]])

    summary = Runs.summary(Repo.get!(Run, ctx.run.id))
    refute Map.has_key?(summary, :error)

    assert %{
             attempt: 1,
             daemon: "test-machine",
             summary: "Partial.",
             usage: %{"input_tokens" => 3},
             events_seq: 12,
             retry_of_id: nil,
             cancel_requested_by: nil,
             claimed_at: nil,
             started_at: nil,
             finished_at: nil,
             last_event_at: nil
           } = summary

    assert summary.retry_run_id == retry.id
    assert summary.initiator == %{id: ctx.bob.id, name: ctx.bob.display_name}
    assert summary.agent_owner_id == ctx.alice.id

    retry_summary = Runs.summary(Repo.get!(Run, retry.id))
    assert retry_summary.retry_of_id == ctx.run.id
    assert [%{kind: "retry", auto: true, retry_of: id, by: nil}] = retry_summary.triggers
    assert id == ctx.run.id
  end

  test "retries merged into a queued run point at it (code review 1)", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    trigger = trigger("assign", ctx.workspace, ctx.alice, ctx.agent)

    failed =
      for _ <- 1..2 do
        run_fixture(ctx.agent, %{
          task_id: task.id,
          status: :failed,
          failure_reason: :timeout,
          triggers: [trigger],
          finished_at: DateTime.utc_now()
        })
      end

    queued = run_fixture(ctx.agent, %{task_id: task.id, triggers: [trigger]})
    Repo.update_all(from(r in Run, where: r.id == ^queued.id), set: [status: :queued])

    for run <- failed, do: assert({:ok, :retried} = Runs.Retry.perform(run.id))

    reloaded = Repo.all(from(r in Run, where: r.id in ^Enum.map(failed, & &1.id), order_by: r.id))
    {:ok, listed} = Runs.list_for_task(ctx.alice_scope, task.ident)

    for run <- reloaded do
      assert Runs.summary(run).retry_run_id == queued.id
      assert Enum.find(listed, &(&1.id == run.id)).retry_run_id == queued.id
      assert Runs.retry(ctx.alice_scope, run.id) |> elem(1) |> Map.get(:id) == queued.id
    end

    assert Enum.find(listed, &(&1.id == queued.id)).retry_run_id == nil
  end

  test "get/2: everyone reads the summary, members the error", ctx do
    assert {:ok, summary} = Runs.get(ctx.viewer_scope, ctx.run.id)
    refute Map.has_key?(summary, :error)
    assert {:ok, %{error: "stack trace"}} = Runs.get(ctx.bob_scope, ctx.run.id)
  end

  test "list_events/3: members only, by sequence number", ctx do
    assert Runs.list_events(ctx.viewer_scope, ctx.run.id) == {:error, :forbidden}
    assert Runs.list_events(ctx.alice_scope, 999_999_999) == {:error, :not_found}

    assert {:ok, %{events: [first | _] = events, pruned: false, last_seq: 12}} =
             Runs.list_events(ctx.bob_scope, ctx.run.id)

    assert length(events) == 12
    assert %{seq: 1, type: "text", data: %{"text" => "1"}, at: %DateTime{}} = first

    assert seqs(Runs.list_events(ctx.bob_scope, ctx.run.id, after_seq: 4, limit: 3)) == [5, 6, 7]
    assert seqs(Runs.list_events(ctx.bob_scope, ctx.run.id, before_seq: 4, limit: 2)) == [2, 3]

    assert seqs(Runs.list_events(ctx.bob_scope, ctx.run.id, latest: true, limit: 3)) == [
             10,
             11,
             12
           ]
  end

  test "list_events/3 reads only up to the run's last sequence number", ctx do
    # An event saved past events_seq (another transaction in flight).
    Repo.insert_all(RunEvent, [
      %{run_id: ctx.run.id, seq: 13, type: "text", data: %{}, at: DateTime.utc_now()}
    ])

    assert {:ok, %{last_seq: 12} = page} =
             Runs.list_events(ctx.bob_scope, ctx.run.id, latest: true, limit: 1)

    assert seqs({:ok, page}) == [12]
  end

  test "can?/3 follows the policy of cancel_run and retry_run", ctx do
    summary = Runs.summary(ctx.run)
    {_carol, carol_scope} = member_scope_fixture(ctx.workspace)

    for action <- [:cancel, :retry] do
      assert Runs.can?(ctx.alice_scope, action, summary)
      assert Runs.can?(ctx.bob_scope, action, summary)
      refute Runs.can?(carol_scope, action, summary)
      refute Runs.can?(ctx.viewer_scope, action, summary)
    end
  end

  describe "notifications" do
    test "claimed → running is seen on run:<id> (scenario)", ctx do
      run = run_fixture(ctx.agent)
      Events.subscribe(Events.topic(:run, run.id))
      dctx = daemon_ctx(ctx.daemon)

      {:ok, [_spec]} = Runs.claim(dctx, "http://localhost")
      assert_receive {:run_updated, %{status: "claimed"}}
      {:ok, :proceed} = Runs.starting(dctx, run.id)
      assert_receive {:run_updated, %{status: "running", started_at: %DateTime{}}}
    end

    test "a check that fails at claim, and stopping, are notified on every topic", ctx do
      task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
      [run] = runs_of(task.id)
      Events.subscribe(Events.topic(:run, run.id))
      Events.subscribe(Events.topic(:workspace_runs, ctx.workspace.id))
      Events.subscribe(Events.topic(:task, task.id))

      {:ok, _} = Tasks.transition(ctx.alice_scope, task.ident, :cancelled)
      assert {:ok, []} = Runs.claim(daemon_ctx(ctx.daemon), "http://localhost")
      id = run.id
      ident = task.ident
      assert_receive {:run_updated, %{id: ^id, status: "cancelled", failure_reason: "obsolete"}}
      assert_receive {:run_updated, %{id: ^id, status: "cancelled"}}
      assert_receive {:runs_changed, ^ident}

      running = run_fixture(ctx.agent, %{status: :running, daemon_id: ctx.daemon.id})
      Events.subscribe(Events.topic(:run, running.id))
      {:ok, _} = Runs.cancel(ctx.alice_scope, running.id)
      running_id = running.id
      assert_receive {:run_updated, %{id: ^running_id, status: "cancelling"}}
    end
  end
end
