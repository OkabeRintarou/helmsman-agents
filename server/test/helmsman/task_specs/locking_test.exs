defmodule Helmsman.TaskSpecs.LockingTest do
  # add-spec-workflow 1.7 / 2.2: task-specs 「规格写入的加锁」 (decision 13)
  # and the run-end barrier of spec-dispatch 「评审请求随运行结算」. The
  # concurrent writes commit on connections of their own.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AgentsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.{CommittedData, Feedback, LockHarness, Repo, Squads, Tasks, TaskSpecs}
  alias Helmsman.Runs.{Run, TaskGrant}
  alias Helmsman.Runs.Workers.SideEffect
  alias Helmsman.TaskSpecs.{Event, Review, ReviewRequest, Version}
  alias HelmsmanProtocol.Report.Finished

  @moduletag timeout: 60_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = specs_fixture()

        for name <- ~w(keel/x keel/x2 keel/x3) do
          managed_agent_fixture(ctx.alice_scope, %{
            name: name,
            runtime_id: ctx.runtime_id,
            access: "workspace"
          })
        end

        {lead, _} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})
        {fe, _} = agent_run_scope(ctx.fe, ctx.task)
        spec_fixture(ctx.alice_scope, ctx.task.ident)

        {:ok, %{version: 2}} =
          TaskSpecs.submit_version(fe, ctx.task.ident, %{
            base_version: 1,
            files: spec_files(tag: "v2")
          })

        bob = human_actor(ctx.workspace, ctx.bob).name
        Repo.delete_all(from(r in Run, where: r.status == :queued))

        Map.merge(ctx, %{ident: ctx.task.ident, lead_scope: lead, fe_scope: fe, bob_name: bob})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, ctx.carol.id]) end)
    ctx
  end

  defp unboxed(fun), do: CommittedData.unboxed(fun)

  defp with_hook(hook, fun) do
    Process.put(:helmsman_test_hook, hook)

    try do
      fun.()
    after
      Process.delete(:helmsman_test_hook)
    end
  end

  # Commits `fun` on a connection of its own, now.
  defp commit!(fun), do: Task.async(fn -> unboxed(fun) end) |> Task.await(10_000)

  # Makes `name` the task's assignee directly, with an `assign` grant by
  # alice: what a concurrent reassignment leaves.
  defp reassign!(ctx, name) do
    commit!(fn ->
      agent = agent_actor(ctx.workspace, name)

      Repo.update_all(from(t in Helmsman.Tasks.Task, where: t.id == ^ctx.task.id),
        set: [assignee_id: agent.id]
      )

      Repo.delete_all(
        from(g in TaskGrant, where: g.task_id == ^ctx.task.id and g.kind == :assign)
      )

      Repo.insert!(%TaskGrant{
        workspace_id: ctx.workspace.id,
        task_id: ctx.task.id,
        agent_id: agent.id,
        kind: :assign,
        root_initiator_user_id: ctx.alice.id,
        causal_agent_ids: [],
        granted_by_id: human_actor(ctx.workspace, ctx.alice).id,
        inserted_at: DateTime.utc_now()
      })
    end)
  end

  defp bob_review(ctx) do
    TaskSpecs.submit_review(ctx.bob_scope, ctx.ident, %{version: 2, verdict: "fail"})
  end

  defp wakes(kind) do
    rows =
      unboxed(fn ->
        Repo.all(from(r in Run, where: r.status == :queued, select: {r.agent_id, r.triggers}))
      end)

    for {agent, triggers} <- rows, %{"kind" => ^kind} <- triggers, do: agent
  end

  defp count(schema), do: unboxed(fn -> Repo.aggregate(schema, :count) end)

  test "a review and a new version at once: serialized, no deadlock", ctx do
    {review, _} = unboxed(fn -> agent_run_scope(ctx.review, ctx.task) end)

    version =
      LockHarness.start(
        fn ->
          TaskSpecs.submit_version(ctx.fe_scope, ctx.ident, %{
            base_version: 2,
            files: spec_files(tag: "v3")
          })
        end,
        pause: :commit
      )

    LockHarness.await_paused(version)

    reviewing =
      LockHarness.start(fn ->
        TaskSpecs.submit_review(review, ctx.ident, %{version: 2, verdict: "pass"})
      end)

    LockHarness.await_blocked(reviewing)
    LockHarness.continue(version)

    assert {:ok, %{version: 3}} = LockHarness.result(version)
    assert {:error, {:spec, :stale_version, 3}} = LockHarness.result(reviewing)
    assert count(Review) == 0
  end

  test "the review first: the version still goes in", ctx do
    {review, _} = unboxed(fn -> agent_run_scope(ctx.review, ctx.task) end)

    reviewing =
      LockHarness.start(
        fn -> TaskSpecs.submit_review(review, ctx.ident, %{version: 2, verdict: "pass"}) end,
        pause: :commit
      )

    LockHarness.await_paused(reviewing)

    version =
      LockHarness.start(fn ->
        TaskSpecs.submit_version(ctx.fe_scope, ctx.ident, %{
          base_version: 2,
          files: spec_files(tag: "v3")
        })
      end)

    LockHarness.await_blocked(version)
    LockHarness.continue(reviewing)
    assert {:ok, %{review: 1}} = LockHarness.result(reviewing)
    assert {:ok, %{version: 3}} = LockHarness.result(version)
  end

  describe "a person's review that wakes the coordinator" do
    setup ctx do
      unboxed(fn ->
        {:ok, %{result: :requested}} =
          Squads.delegate(ctx.lead_scope, ctx.ident, ctx.bob_name, "Review", "review")
      end)

      :ok
    end

    test "reassigned between the guess and the task lock: the new assignee, once", ctx do
      hook = fn
        {:dispatch_targets, 1} -> reassign!(ctx, "keel/x")
        _other -> :ok
      end

      assert {:ok, %{review: 1, dispatch: %{target: "keel/x"}}} =
               unboxed(fn -> with_hook(hook, fn -> bob_review(ctx) end) end)

      x = unboxed(fn -> agent_actor(ctx.workspace, "keel/x").id end)
      assert wakes("spec_reviewed") == [x]
      assert count(Review) == 1
    end

    test "the target changing every round: busy after 3, nothing written", ctx do
      names = %{1 => "keel/x", 2 => "keel/x2", 3 => "keel/x3"}

      hook = fn
        {:dispatch_targets, n} -> reassign!(ctx, names[n])
        _other -> :ok
      end

      assert {:error, :busy} = unboxed(fn -> with_hook(hook, fn -> bob_review(ctx) end) end)
      assert count(Review) == 0
      assert wakes("spec_reviewed") == []
      assert unboxed(fn -> Repo.one!(ReviewRequest).status end) == :requested
    end

    test "the leader changed after the guess: the new leader is woken", ctx do
      hook = fn
        {:spec_guessed, :submit_review} ->
          commit!(fn ->
            x = agent_actor(ctx.workspace, "keel/x")

            Repo.update_all(from(s in Helmsman.Squads.Squad, where: s.id == ^ctx.squad.id),
              set: [leader_agent_id: x.id]
            )
          end)

        _other ->
          :ok
      end

      assert {:ok, %{dispatch: %{target: "keel/x", squad: "web-team"}}} =
               unboxed(fn -> with_hook(hook, fn -> bob_review(ctx) end) end)

      assert length(wakes("spec_reviewed")) == 1
    end

    test "with a change of the person's review and of the task at once: both finish", ctx do
      reviewing = LockHarness.start(fn -> bob_review(ctx) end)

      reassigning =
        LockHarness.start(fn ->
          {:ok, _} = Tasks.update(ctx.alice_scope, ctx.ident, %{assignee: "keel/dev"})

          Feedback.add(ctx.alice_scope, ctx.ident, %{
            kind: :comment,
            content: "Moved to keel/dev"
          })
        end)

      assert {:ok, %{review: 1}} = LockHarness.result(reviewing)
      assert {:ok, _} = LockHarness.result(reassigning)
      assert length(wakes("spec_reviewed")) == 1
    end
  end

  test "an agent's access changed after the guess: skipped, the request stays", ctx do
    hook = fn
      {:spec_guessed, :request_reviews} ->
        commit!(fn ->
          review = agent_actor(ctx.workspace, "keel/review")

          Repo.update_all(
            from(p in Helmsman.Agents.AgentProfile, where: p.actor_id == ^review.id),
            set: [access: "owner_only"]
          )
        end)

      _other ->
        :ok
    end

    assert {:ok, %{requests: [%{dispatch: %{result: :skipped, reason: :unauthorized}}]}} =
             unboxed(fn ->
               with_hook(hook, fn ->
                 TaskSpecs.request_reviews(ctx.bob_scope, ctx.ident, ["keel/review"])
               end)
             end)

    assert count(ReviewRequest) == 1
  end

  test "a review run ending while a spec write holds the task and spec", ctx do
    {:ok, %{result: :queued}} =
      unboxed(fn ->
        Squads.delegate(ctx.lead_scope, ctx.ident, "keel/review", "Review", "review")
      end)

    daemon = unboxed(fn -> daemon_of(ctx.review) end)

    run =
      unboxed(fn ->
        run =
          Repo.one!(from(r in Run, where: r.agent_id == ^ctx.review.id and r.status == :queued))

        set_run!(run.id,
          status: :running,
          daemon_id: daemon.id,
          claimed_at: DateTime.utc_now(),
          started_at: DateTime.utc_now()
        )

        Repo.get!(Run, run.id)
      end)

    {review_scope, _token} = unboxed(fn -> run_scope_fixture(run) end)

    # Connection A: the run's terminal transaction, holding the run row.
    ending =
      LockHarness.start(
        fn ->
          :ok = Helmsman.Runs.finish(dctx(ctx.review), finished(run.id))
          {:ok, :ended}
        end,
        pause: :commit
      )

    LockHarness.await_paused(ending)

    # Connection B: the run's own spec write, holding the task and spec
    # rows, then checking its token (the run row, FOR SHARE).
    writing =
      LockHarness.start(fn ->
        TaskSpecs.submit_review(review_scope, ctx.ident, %{version: 2, verdict: "pass"})
      end)

    LockHarness.await_blocked(writing)
    LockHarness.continue(ending)

    assert {:ok, :ended} = LockHarness.result(ending)
    assert {:error, :run_ended} = LockHarness.result(writing)

    unboxed(fn ->
      for _ <- 1..2,
          do:
            :ok =
              SideEffect.perform(%Oban.Job{args: %{"run_id" => run.id, "kind" => "spec_settle"}})

      assert Repo.one!(ReviewRequest).status == :lapsed

      assert Repo.aggregate(from(e in Event, where: e.action == "review_request_closed"), :count) ==
               1

      assert Repo.aggregate(Version, :count) == 2
    end)
  end

  defp finished(run_id) do
    {:ok, report} = Finished.new(%{run_id: run_id, status: :succeeded})
    report
  end

  describe "who coordinates, under the locks (code-review-1 P1-1)" do
    setup ctx do
      {:ok, admin} = {:ok, ctx.alice_scope}
      unboxed(fn -> {:ok, _} = Squads.update(admin, "web-team", %{spec_finalize: "leader"}) end)
      :ok
    end

    defp finalize_as_leader(ctx),
      do: TaskSpecs.finalize(ctx.lead_scope, ctx.ident, %{version: 2, summary: "Reviewed"})

    defp set_squad_mode!(ctx, mode),
      do:
        commit!(fn ->
          {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{spec_finalize: mode})
        end)

    test "the squad tightened to approval after the guess: only a proposal", ctx do
      side = LockHarness.start(fn -> finalize_as_leader(ctx) end, pause: {:spec_guessed, :decide})
      LockHarness.await_paused(side)
      set_squad_mode!(ctx, "approval")
      LockHarness.continue(side)

      assert {:ok, %{decision: :proposed, spec: %{status: :pending_approval}}} =
               LockHarness.result(side)
    end

    test "the finalize first: the tightening waits for it", ctx do
      side = LockHarness.start(fn -> finalize_as_leader(ctx) end, pause: :commit)
      LockHarness.await_paused(side)

      tightening =
        LockHarness.start(fn ->
          Squads.update(ctx.alice_scope, "web-team", %{spec_finalize: "approval"})
        end)

      LockHarness.await_blocked(tightening)
      LockHarness.continue(side)
      assert {:ok, %{decision: :finalized}} = LockHarness.result(side)
      assert {:ok, _} = LockHarness.result(tightening)
    end

    test "the project tightened after the guess (the squad inherits it)", ctx do
      set_squad_mode!(ctx, nil)

      commit!(fn ->
        {:ok, _} =
          Helmsman.Projects.update(ctx.alice_scope, ctx.project.key, %{spec_finalize: "leader"})
      end)

      side = LockHarness.start(fn -> finalize_as_leader(ctx) end, pause: {:spec_guessed, :decide})
      LockHarness.await_paused(side)

      commit!(fn ->
        {:ok, _} =
          Helmsman.Projects.update(ctx.alice_scope, ctx.project.key, %{spec_finalize: "approval"})
      end)

      LockHarness.continue(side)
      assert {:ok, %{decision: :proposed}} = LockHarness.result(side)
    end

    test "the finalize first: the project change waits for it", ctx do
      set_squad_mode!(ctx, nil)

      commit!(fn ->
        {:ok, _} =
          Helmsman.Projects.update(ctx.alice_scope, ctx.project.key, %{spec_finalize: "leader"})
      end)

      side = LockHarness.start(fn -> finalize_as_leader(ctx) end, pause: :commit)
      LockHarness.await_paused(side)

      changing =
        LockHarness.start(fn ->
          Helmsman.Projects.update(ctx.alice_scope, ctx.project.key, %{spec_finalize: "approval"})
        end)

      LockHarness.await_blocked(changing)
      LockHarness.continue(side)
      assert {:ok, %{decision: :finalized}} = LockHarness.result(side)
      assert {:ok, _} = LockHarness.result(changing)
    end

    test "the leader replaced after the guess: no longer a coordinator", ctx do
      side = LockHarness.start(fn -> finalize_as_leader(ctx) end, pause: {:spec_guessed, :decide})
      LockHarness.await_paused(side)

      commit!(fn ->
        {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/x"})
      end)

      LockHarness.continue(side)

      assert {:error, {:spec, :not_coordinator, _}} = LockHarness.result(side)

      # Abandoning (a coordinated write without targets) checks it too.
      assert {:error, {:spec, :not_coordinator, _}} =
               unboxed(fn -> TaskSpecs.abandon(ctx.lead_scope, ctx.ident, %{reason: "x"}) end)
    end
  end

  test "a reviewer's name taken over after the guess: the current identity (code-review-1 P2-2)",
       ctx do
    side =
      LockHarness.start(
        fn -> TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"]) end,
        pause: {:spec_guessed, :request_reviews}
      )

    LockHarness.await_paused(side)

    new_id =
      commit!(fn ->
        old = agent_actor(ctx.workspace, "keel/review")

        Repo.update_all(from(a in Helmsman.Actors.Actor, where: a.id == ^old.id),
          set: [name: "keel/old-review"]
        )

        managed_agent_fixture(ctx.alice_scope, %{
          name: "keel/review",
          runtime_id: ctx.runtime_id,
          access: "workspace"
        })

        agent_actor(ctx.workspace, "keel/review").id
      end)

    LockHarness.continue(side)

    assert {:ok, %{requests: [%{reviewer: "keel/review", dispatch: %{target: "keel/review"}}]}} =
             LockHarness.result(side)

    assert unboxed(fn -> Repo.one!(ReviewRequest).reviewer_id end) == new_id
  end
end
