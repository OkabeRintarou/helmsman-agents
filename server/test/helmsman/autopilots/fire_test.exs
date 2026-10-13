defmodule Helmsman.Autopilots.FireTest do
  # add-autopilots 3.1: one trigger's execution (specs/autopilot-execution
  # "一次触发的执行", specs/autopilots "授权来源" queue and snapshot
  # scenarios).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentsFixtures
  import Helmsman.AutopilotsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, Autopilots, Members, Runtimes, Workspaces}
  alias Helmsman.Autopilots.Workers.{Fire, StartPending}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Membership

  setup do
    ctx = autopilots_fixture()

    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/c",
      runtime_id: profile(ctx.agent).runtime_id,
      access: "owner_only"
    })

    ctx
  end

  defp webhook(scope, view) do
    {:ok, %{token: token}} = Autopilots.enable_webhook(scope, view.id)
    token
  end

  defp deliver(view, token, delivery_id, body \\ ~s({"ok":true})) do
    {:ok, hash} = Autopilots.authenticate_webhook(view.id, token)
    Autopilots.fire_webhook(view.id, hash, delivery_id, body, "application/json")
  end

  defp done!(%{task_id: id}),
    do: Repo.update_all(from(t in Task, where: t.id == ^id), set: [status: :done])

  defp start_pending_jobs do
    for %{args: %{"autopilot_run_id" => id}} <- all_enqueued(worker: StartPending), do: id
  end

  defp run_start_pending do
    for id <- start_pending_jobs(),
        do: assert(:ok = perform_job(StartPending, %{autopilot_run_id: id}))
  end

  defp fire_at(view, at),
    do: perform_job(Fire, %{autopilot_id: view.id, at: DateTime.to_iso8601(at)})

  defp tasks_count, do: Repo.aggregate(Task, :count)

  test "skip: the previous task still in progress → skipped / overlap, no new task", ctx do
    view = autopilot_fixture(ctx.alice_scope, %{cron: "0 9 * * *"})
    {:ok, r0} = Autopilots.run_now(ctx.alice_scope, view.id)
    assert r0.status == :started and r0.task_id

    at(autopilot_row(view).next_run_at)
    assert :ok = fire_at(view, autopilot_row(view).next_run_at)

    [_, skipped] = records_of(view)
    assert {skipped.status, skipped.reason} == {:skipped, "overlap"}
    assert skipped.result =~ "#{r0.id}"
    assert tasks_count() == 1
  end

  test "queue keeps only the newest: d-1 superseded, d-2 pending, then run with its payload",
       ctx do
    view = autopilot_fixture(ctx.alice_scope, %{overlap: "queue"})
    {:ok, r0} = Autopilots.run_now(ctx.alice_scope, view.id)
    token = webhook(ctx.alice_scope, view)

    {:ok, d1} = deliver(view, token, "d-1", ~s({"n":1}))
    {:ok, d2} = deliver(view, token, "d-2", ~s({"n":2}))
    assert {d2.status, d2.payload} == {:pending, %{"n" => 2}}
    assert %{status: :skipped, reason: "superseded"} = Repo.reload!(d1)

    done!(r0)
    {:ok, _} = Autopilots.settle(view.id)
    assert %{status: :succeeded} = Repo.reload!(r0)
    run_start_pending()

    d2 = Repo.reload!(d2)
    assert d2.status == :started
    task = Repo.get!(Task, d2.task_id)
    assert task.description =~ ~s("n": 2)
    assert tasks_count() == 2
  end

  test "a request just after the work ended settles it in place and supersedes the queued one",
       ctx do
    view = autopilot_fixture(ctx.alice_scope, %{overlap: "queue"})
    {:ok, r0} = Autopilots.run_now(ctx.alice_scope, view.id)
    {:ok, p1} = Autopilots.run_now(ctx.alice_scope, view.id)
    assert p1.status == :pending

    # R0's work is done, not yet settled.
    done!(r0)
    {:ok, r2} = Autopilots.run_now(ctx.alice_scope, view.id)

    assert %{status: :succeeded} = Repo.reload!(r0)
    assert %{status: :skipped, reason: "superseded"} = Repo.reload!(p1)
    assert r2.status == :started

    # The start planned for P1 does nothing; R2 stays the only started.
    assert p1.id in start_pending_jobs()
    run_start_pending()
    assert %{status: :skipped, task_id: nil, run_id: nil} = Repo.reload!(p1)
    assert %{status: :started} = Repo.reload!(r2)
    assert tasks_count() == 2
  end

  test "losing the right to trigger: failed / unauthorized and disabled", ctx do
    view = autopilot_fixture(ctx.bob_scope, %{cron: "0 9 * * *"})
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{access: "owner_only"})

    at = autopilot_row(view).next_run_at
    at(at)
    assert :ok = fire_at(view, at)

    assert [%{status: :failed, reason: "unauthorized"}] = records_of(view)
    assert %{enabled: false, disabled_reason: :unauthorized} = autopilot_row(view)
  end

  test "a disabled runtime: failed / runtime_disabled, one failure, still enabled", ctx do
    view = autopilot_fixture(ctx.alice_scope)
    {:ok, _} = Runtimes.disable(ctx.alice_scope, profile(ctx.agent).runtime_id)

    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    assert {record.status, record.reason} == {:failed, "runtime_disabled"}
    assert %{enabled: true, consecutive_failures: 1} = autopilot_row(view)
  end

  test "a source no longer in the workspace: failed / initiator_left and disabled", ctx do
    view = autopilot_fixture(ctx.bob_scope, %{cron: "0 9 * * *"})
    # The membership goes without the removal's cascade.
    Repo.delete_all(from(m in Membership, where: m.user_id == ^ctx.bob.id))

    at = autopilot_row(view).next_run_at
    at(at)
    assert :ok = fire_at(view, at)

    assert [%{status: :failed, reason: "initiator_left"}] = records_of(view)
    assert %{enabled: false, disabled_reason: :initiator_left} = autopilot_row(view)
  end

  test "the source removed between the read and the write: it starts over, no failure", ctx do
    view = autopilot_fixture(ctx.bob_scope, %{cron: "0 9 * * *"})
    membership = Workspaces.get_membership(ctx.workspace.id, ctx.bob.id)

    Process.put(:helmsman_test_hook, fn
      {:read, :schedule} ->
        if Process.get(:removed) == nil do
          Process.put(:removed, true)
          {:ok, _} = Members.remove(ctx.alice_scope, membership.id)
        end

      _ ->
        :ok
    end)

    at = DateTime.add(DateTime.utc_now(), 60)

    Repo.update_all(from(a in Autopilots.Autopilot, where: a.id == ^view.id),
      set: [next_run_at: at]
    )

    assert {:ok, :noop} = Helmsman.Autopilots.Fire.request(view.id, {:schedule, at})
    Process.delete(:helmsman_test_hook)

    assert records_of(view) == []
    assert %{enabled: false, disabled_reason: :initiator_left} = autopilot_row(view)
  end

  test "a queued request runs with its own initiator and frozen configuration", ctx do
    view = autopilot_fixture(ctx.alice_scope, %{overlap: "queue", agent: "keel/dev"})
    {:ok, r0} = Autopilots.run_now(ctx.alice_scope, view.id)
    {:ok, p} = Autopilots.run_now(ctx.bob_scope, view.id, "from bob")
    assert p.initiator_user_id == ctx.bob.id

    done!(r0)
    {:ok, _} = Autopilots.settle(view.id)
    [id] = start_pending_jobs()
    # Twice: started once.
    assert :ok = perform_job(StartPending, %{autopilot_run_id: id})
    assert :ok = perform_job(StartPending, %{autopilot_run_id: id})

    p = Repo.reload!(p)
    assert p.status == :started
    task = Repo.get!(Task, p.task_id)
    assert task.created_by_id == ctx.bob_scope.actor.id
    assert task.description =~ "from bob"
    assert tasks_count() == 2
    assert Repo.get!(Run, p.run_id).root_initiator_user_id == ctx.bob.id
  end

  test "a queued request when someone else changes the configuration: config_changed", ctx do
    view = autopilot_fixture(ctx.alice_scope, %{overlap: "queue", agent: "keel/dev"})
    {:ok, r0} = Autopilots.run_now(ctx.alice_scope, view.id)
    token = webhook(ctx.alice_scope, view)
    {:ok, pending} = deliver(view, token, "d-1")
    assert pending.status == :pending

    {:ok, _} = Autopilots.update(ctx.bob_scope, view.id, %{instructions: "@keel/c do X"})
    assert %{status: :cancelled, reason: "config_changed"} = Repo.reload!(pending)

    done!(r0)
    {:ok, _} = Autopilots.settle(view.id)
    assert start_pending_jobs() == []
    assert tasks_count() == 1
  end

  describe "the source moved before a queued request runs" do
    setup ctx do
      at(~U[2026-10-14 08:00:00Z])

      view =
        autopilot_fixture(ctx.carol_scope, %{
          overlap: "queue",
          agent: "keel/dev",
          cron: "0 9 * * *"
        })

      {:ok, %{token: _}} = Autopilots.enable_webhook(ctx.carol_scope, view.id)
      {:ok, r0} = Autopilots.run_now(ctx.carol_scope, view.id)

      at(~U[2026-10-14 09:00:00Z])
      assert :ok = fire_at(view, ~U[2026-10-14 09:00:00.000000Z])
      [_, p] = records_of(view)
      assert {p.status, p.source, p.initiator_user_id} == {:pending, :schedule, ctx.carol.id}

      Map.merge(ctx, %{view: view, r0: r0, p: p})
    end

    defp move(ctx, :cron),
      do: Autopilots.update(ctx.bob_scope, ctx.view.id, %{cron: "0 10 * * *"})

    defp move(ctx, :webhook), do: Autopilots.enable_webhook(ctx.bob_scope, ctx.view.id)
    defp move(ctx, :rotate), do: Autopilots.rotate_webhook_token(ctx.bob_scope, ctx.view.id)

    for label <- [:cron, :webhook, :rotate] do
      @label label
      test "by #{label}: it starts once, still carol's, with its snapshot", ctx do
        {:ok, _} = move(ctx, @label)
        assert autopilot_row(ctx.view).initiator_user_id == ctx.bob.id
        assert Repo.reload!(ctx.p).status == :pending

        done!(ctx.r0)
        {:ok, _} = Autopilots.settle(ctx.view.id)
        run_start_pending()
        run_start_pending()

        p = Repo.reload!(ctx.p)
        assert {p.status, p.initiator_user_id} == {:started, ctx.carol.id}
        assert Repo.get!(Task, p.task_id).created_by_id == ctx.carol_scope.actor.id
        assert p.config == ctx.p.config
        assert tasks_count() == 2
      end

      test "by #{label}, then carol leaves: cancelled / initiator_left, bob's stays enabled",
           ctx do
        {:ok, _} = move(ctx, @label)
        membership = Workspaces.get_membership(ctx.workspace.id, ctx.carol.id)
        {:ok, _} = Members.remove(ctx.alice_scope, membership.id)

        done!(ctx.r0)
        {:ok, _} = Autopilots.settle(ctx.view.id)
        run_start_pending()

        assert %{status: :cancelled, reason: "initiator_left"} = Repo.reload!(ctx.p)
        row = autopilot_row(ctx.view)

        assert {row.enabled, row.initiator_user_id, row.consecutive_failures} ==
                 {true, ctx.bob.id, 0}

        assert tasks_count() == 1
      end
    end
  end
end
