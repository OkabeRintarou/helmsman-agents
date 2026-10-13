defmodule Helmsman.Dispatch.WakeupRaceTest do
  # add-dependency-dispatch 1.10: no wake-up is lost (decisions 5, 13), on
  # connections of their own with test hooks.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.DependencyFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Agents.AgentProfile
  alias Helmsman.CommittedData
  alias Helmsman.Daemons.Daemon
  alias Helmsman.GitHub.PullRequest
  alias Helmsman.GitHub.PullRequests.Reconcile
  alias Helmsman.{LockHarness, Repo, Runs}
  alias Helmsman.Runs.{Lifecycle, Run}
  alias Helmsman.{Tasks, Tx}

  @moduletag timeout: 60_000

  setup do
    ctx = CommittedData.unboxed(fn -> dependency_fixture() end)
    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  defp committed(fun), do: CommittedData.unboxed(fun)

  defp web2_runs(ctx),
    do:
      committed(fn ->
        Repo.all(
          from(r in Run,
            where: r.task_id == ^ctx.web2.id and r.status in [:deferred, :queued],
            select: r.status
          )
        )
      end)

  defp drain, do: committed(fn -> Oban.drain_queue(queue: :default) end)

  describe "指派与前置完成并发" do
    setup ctx do
      committed(fn ->
        {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "in_progress")
      end)

      :ok
    end

    defp assign(ctx),
      do: fn -> Tasks.update(ctx.alice_scope, ctx.web2.ident, %{assignee: "keel/dev"}) end

    defp finish(ctx), do: fn -> Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "done") end

    test "the assignment reads the dependencies first", ctx do
      {micros, {a, b}} =
        :timer.tc(fn -> LockHarness.interleave(assign(ctx), :dependencies_read, finish(ctx)) end)

      assert {:ok, %{dispatch: [%{result: :deferred}]}} = a
      assert {:ok, %{status: "done"}} = b
      assert micros < 5_000_000
      assert web2_runs(ctx) == [:queued]
    end

    test "the prerequisite is done first", ctx do
      {micros, {b, a}} =
        :timer.tc(fn -> LockHarness.interleave(finish(ctx), :commit, assign(ctx)) end)

      assert {:ok, %{status: "done"}} = b
      assert {:ok, %{dispatch: [%{result: :queued}]}} = a
      assert micros < 5_000_000
      assert web2_runs(ctx) == [:queued]
    end
  end

  describe "领取复查" do
    setup ctx do
      committed(fn ->
        Repo.update_all(AgentProfile, set: [max_concurrency: 5])
        daemon = daemon_of(ctx.agent)
        Repo.update_all(from(d in Daemon, where: d.id == ^daemon.id), set: [max_concurrency: 5])
        put_assignee!(ctx.web2, ctx.agent.id)
        run_with!(ctx, ctx.web2, :queued, ["assign"])
      end)

      Map.put(ctx, :dctx, daemon_ctx(committed(fn -> daemon_of(ctx.agent) end)))
    end

    # Claiming pauses after reading an unsatisfied prerequisite; `change`
    # commits meanwhile on another connection; then claiming goes on.
    defp race(ctx, change) do
      claimer =
        LockHarness.start(fn -> Runs.claim(ctx.dctx, "http://localhost:4000") end,
          pause: :dependencies_rechecked
        )

      LockHarness.await_paused(claimer)
      committed(change)
      LockHarness.continue(claimer)
      assert {:ok, {:ok, []}} = {:ok, LockHarness.result(claimer)}
      assert web2_runs(ctx) == [:deferred]
      drain()
      assert web2_runs(ctx) == [:queued]
    end

    test "领取复查与运行结束并发", ctx do
      run =
        committed(fn ->
          put_status!(ctx.bos1, :done)

          run_fixture(ctx.agent, %{
            task_id: ctx.bos1.id,
            status: :running,
            daemon_id: daemon_of(ctx.agent).id,
            claimed_at: DateTime.utc_now()
          })
        end)

      race(ctx, fn ->
        {:ok, _} =
          Tx.run(fn ->
            locked = Repo.one!(from(r in Run, where: r.id == ^run.id, lock: "FOR UPDATE"))
            {:ok, Lifecycle.end!(locked, :succeeded)}
          end)
      end)
    end

    test "领取复查与 PR 首次记为已合并", ctx do
      {task, row} =
        committed(fn ->
          installation = installation_fixture(ctx.workspace)
          repo = repository_fixture(installation, %{owner: "acme", name: "app"})
          bind_repository(ctx.project, repo)
          put_status!(ctx.bos1, :verified)
          head = String.duplicate("c", 40)

          run_fixture(ctx.agent, %{
            task_id: ctx.bos1.id,
            status: :succeeded,
            repository_id: repo.id,
            claimed_at: DateTime.utc_now(),
            branch: "b",
            base_sha: String.duplicate("0", 40),
            head_sha: head,
            push_status: :pushed,
            pushed_at: DateTime.utc_now()
          })

          row =
            Repo.insert!(%PullRequest{
              workspace_id: ctx.workspace.id,
              task_id: ctx.bos1.id,
              repository_id: repo.id,
              number: 1,
              node_id: "n",
              url: "u",
              branch: "b",
              base_branch: "main",
              state: :open,
              head_sha: head
            })

          {Repo.reload!(ctx.bos1), row}
        end)

      race(ctx, fn ->
        {:ok, _} =
          Tx.run(fn ->
            {:ok,
             Reconcile.update_row(
               row,
               [state: :merged, merged_at: DateTime.utc_now(), included_sha: row.head_sha],
               task
             )}
          end)
      end)
    end
  end

  describe "ON CONFLICT after waiting for an uncommitted insert (code review 1 P2)" do
    test "a deferred row committed meanwhile becomes queued and the daemon is told", ctx do
      {attrs, daemon_id} =
        committed(fn ->
          put_assignee!(ctx.web2, ctx.agent.id)
          profile = profile(ctx.agent)

          attrs = %{
            workspace_id: ctx.workspace.id,
            agent_id: ctx.agent.id,
            runtime_id: profile.runtime_id,
            task_id: ctx.web2.id,
            lane: :work,
            status: :queued,
            trigger: trigger("manual", ctx.workspace, ctx.alice, ctx.agent),
            root_initiator_user_id: ctx.alice.id,
            causal_agent_ids: [ctx.agent.id],
            capabilities: ["read", "write_task"],
            priority: 2
          }

          {attrs, daemon_of(ctx.agent).id}
        end)

      Helmsman.Events.subscribe(Helmsman.Events.topic(:daemon, daemon_id))

      inserter =
        LockHarness.start(fn -> run_with!(ctx, ctx.web2, :deferred, ["assign"]) end,
          pause: :commit
        )

      LockHarness.await_paused(inserter)
      merger = LockHarness.start(fn -> Runs.upsert_pending(attrs, rate_limit?: false) end)
      LockHarness.await_blocked(merger)
      LockHarness.continue(inserter)
      deferred = LockHarness.result(inserter)

      assert {:merged, %Run{id: id, status: :queued}} = LockHarness.result(merger)
      assert id == deferred.id
      assert_receive {:runs_available}, 2_000

      assert [%Run{id: ^id, triggers: triggers}] =
               committed(fn ->
                 Repo.all(
                   from(r in Run,
                     where: r.task_id == ^ctx.web2.id and r.status in [:deferred, :queued]
                   )
                 )
               end)

      assert Enum.map(triggers, & &1["kind"]) == ["assign", "manual"]
    end
  end
end
