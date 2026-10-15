defmodule Helmsman.TaskSpecs.ReviewDispatchTest do
  # add-spec-workflow 2.2: spec-dispatch 「请求评审的触发」「评审请求随运行结算」
  # 「规格运行的复核」 (decision 10).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.{Agents, Repo, Runs, Squads, TaskSpecs}
  alias Helmsman.Runs.{Retry, Run, RunTokens, Triggers}
  alias Helmsman.Runs.Workers.SideEffect
  alias Helmsman.TaskSpecs.{Event, ReviewRequest}

  setup do
    ctx = specs_fixture()
    {lead, _} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})
    {fe, _} = agent_run_scope(ctx.fe, ctx.task)
    spec_fixture(ctx.alice_scope, ctx.task.ident)

    {:ok, %{version: 2}} =
      TaskSpecs.submit_version(fe, ctx.task.ident, %{
        base_version: 1,
        files: spec_files(tag: "v2")
      })

    # The leader's assignment run is not part of these tests.
    Repo.delete_all(from(r in Run, where: r.status == :queued))
    Repo.delete_all(Oban.Job)
    Map.merge(ctx, %{ident: ctx.task.ident, lead_scope: lead, daemon: daemon_of(ctx.review)})
  end

  defp request!(ctx) do
    ctx.review |> runs() |> Enum.each(&Repo.delete!/1)

    {:ok, %{result: :queued, request: 1}} =
      Squads.delegate(ctx.lead_scope, ctx.ident, "keel/review", "Review v2", "review")

    [run] = runs(ctx.review)
    run
  end

  defp runs(agent, status \\ :queued),
    do: Repo.all(from(r in Run, where: r.agent_id == ^agent.id and r.status == ^status))

  # The review run, claimed by its daemon and running.
  defp running!(ctx, run) do
    set_run!(run.id,
      status: :running,
      daemon_id: ctx.daemon.id,
      claimed_at: DateTime.utc_now(),
      started_at: DateTime.utc_now()
    )

    Repo.get!(Run, run.id)
  end

  # Claiming needs the task free of active runs (the scopes' runs end) and
  # the run due.
  defp claimable!(ctx) do
    Repo.update_all(from(r in Run, where: r.task_id == ^ctx.task.id and r.status == :running),
      set: [status: :succeeded, finished_at: DateTime.utc_now()]
    )

    Repo.update_all(from(r in Run, where: r.status == :queued),
      set: [not_before: DateTime.utc_now()]
    )
  end

  defp settle(run), do: perform_job(SideEffect, %{run_id: run.id, kind: "spec_settle"})
  defp done(run), do: perform_job(SideEffect, %{run_id: run.id, kind: "delegate_done"})

  defp job?(run, kind),
    do:
      Repo.exists?(
        from(j in Oban.Job, where: j.args["run_id"] == ^run.id and j.args["kind"] == ^kind)
      )

  defp request, do: Repo.one!(ReviewRequest)

  defp closed_events,
    do: Repo.aggregate(from(e in Event, where: e.action == "review_request_closed"), :count)

  describe "请求评审的触发" do
    test "a person asks a managed agent: a new reply run", ctx do
      assert {:ok,
              %{requests: [%{dispatch: %{result: :queued, target: "keel/review", run_id: id}}]}} =
               TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"], %{
                 note: "Focus on concurrency"
               })

      alice = human_actor(ctx.workspace, ctx.alice)

      assert %Run{lane: :reply, root_initiator_user_id: initiator, triggers: [trigger]} =
               Repo.get!(Run, id)

      assert initiator == ctx.alice.id

      assert %{
               "kind" => "spec_review",
               "by_actor_id" => by,
               "spec_request" => 1,
               "spec_version" => 2,
               "instructions" => "Focus on concurrency"
             } = trigger

      assert by == alice.id
      assert %ReviewRequest{status: :requested, request_run_id: nil} = request()
    end

    test "the requester may not trigger the reviewer: the request stays, no run", ctx do
      assert {:ok, %{requests: [%{dispatch: %{result: :skipped, reason: :unauthorized}}]}} =
               TaskSpecs.request_reviews(ctx.carol_scope, ctx.ident, ["keel/qa"])

      assert %ReviewRequest{status: :requested} = request()
      assert runs(ctx.qa) == []
    end
  end

  describe "评审请求随运行结算" do
    test "the review run succeeds without a review: lapsed, then the leader wakes", ctx do
      run = ctx |> request!() |> then(&running!(ctx, &1))
      finish!(ctx.review, run.id, :succeeded)

      assert job?(run, "spec_settle") and job?(run, "delegate_done")
      assert request().status == :requested

      assert :ok = done(run)
      assert %ReviewRequest{status: :lapsed, closed_at: %DateTime{}} = request()

      assert {:ok, %{status: :draft, pending_reviews: []}} =
               TaskSpecs.summary(ctx.alice_scope, ctx.ident)

      assert [%Run{triggers: [%{"kind" => "delegate_done"}]}] = runs(ctx.lead)

      # Both effects, in any order, twice: one settlement.
      assert :ok = settle(run)
      assert :ok = done(run)
      assert :ok = settle(run)
      assert closed_events() == 1
    end

    test "settled before the wake-up, in either order", ctx do
      run = ctx |> request!() |> then(&running!(ctx, &1))
      finish!(ctx.review, run.id, :succeeded)
      assert :ok = settle(run)
      assert request().status == :lapsed
      assert :ok = done(run)
      assert closed_events() == 1
    end

    test "a review submitted in the run: nothing to settle", ctx do
      run = ctx |> request!() |> then(&running!(ctx, &1))
      {scope, _token} = run_scope_fixture(run)
      {:ok, _} = TaskSpecs.submit_review(scope, ctx.ident, %{version: 2, verdict: "pass"})
      finish!(ctx.review, run.id, :succeeded)
      assert :ok = settle(run)
      assert request().status == :submitted
      assert closed_events() == 0
    end

    test "an automatic retry keeps the request; the retry submits", ctx do
      run = ctx |> request!() |> then(&running!(ctx, &1))
      finish!(ctx.review, run.id, :failed, %{failure_reason: :provider_network})

      # The window before the retry job: still requested, no settlement.
      refute job?(run, "spec_settle")
      assert request().status == :requested

      assert {:ok, :retried} = Retry.perform(run.id)
      assert [retry] = runs(ctx.review)
      assert Enum.any?(retry.triggers, &(&1["spec_request"] == 1))

      # Claiming keeps the trigger: the request is still requested.
      claimable!(ctx)
      {:ok, specs} = Runs.claim(dctx(ctx.review), "http://localhost:4000")
      assert %{mcp: %{token: token}} = Enum.find(specs, &(&1.run_id == retry.id))
      assert %Run{status: :claimed, triggers: triggers} = Repo.get!(Run, retry.id)
      assert Enum.any?(triggers, &(&1["spec_request"] == 1))
      start!(ctx.review, retry.id)
      {:ok, scope} = RunTokens.scope(token)
      assert {:ok, _} = TaskSpecs.submit_review(scope, ctx.ident, %{version: 2, verdict: "pass"})
      assert request().status == :submitted
    end

    test "the retry ends without a review: lapsed exactly once", ctx do
      run = ctx |> request!() |> then(&running!(ctx, &1))
      finish!(ctx.review, run.id, :failed, %{failure_reason: :provider_network})
      {:ok, :retried} = Retry.perform(run.id)
      [retry] = runs(ctx.review)
      retry = running!(ctx, retry)
      finish!(ctx.review, retry.id, :succeeded)

      assert job?(retry, "spec_settle")
      assert :ok = settle(retry)
      assert :ok = settle(run)
      assert request().status == :lapsed
      assert closed_events() == 1
    end

    test "the automatic retry is not requeued (agent disabled): lapsed", ctx do
      run = ctx |> request!() |> then(&running!(ctx, &1))
      finish!(ctx.review, run.id, :failed, %{failure_reason: :provider_network})
      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/review")

      assert {:ok, :skipped} = Retry.perform(run.id)
      assert job?(run, "spec_settle")
      assert :ok = settle(run)
      assert request().status == :lapsed
      assert closed_events() == 1
    end

    test "retries used up: settled when the run ends", ctx do
      run = ctx |> request!() |> then(&running!(ctx, &1))
      set_run!(run.id, auto_retries: 3)
      finish!(ctx.review, run.id, :failed, %{failure_reason: :provider_network})
      assert job?(run, "spec_settle")
      assert :ok = settle(run)
      assert request().status == :lapsed
    end

    test "stopped by a person: lapsed, the leader not woken", ctx do
      run = ctx |> request!() |> then(&running!(ctx, &1))
      {:ok, _} = Runs.cancel(ctx.alice_scope, run.id)
      finish!(ctx.review, run.id, :cancelled)

      assert job?(run, "spec_settle")
      refute job?(run, "delegate_done")
      assert :ok = settle(run)
      assert request().status == :lapsed
      assert closed_events() == 1
    end

    test "a manual retry of a settled run drops the trigger when claimed", ctx do
      run = ctx |> request!() |> then(&running!(ctx, &1))
      finish!(ctx.review, run.id, :failed, %{failure_reason: :cli_error})
      :ok = settle(run)

      assert {:ok, %{id: retry_id}} = Retry.retry(ctx.alice_scope, run.id)
      claimable!(ctx)
      claim!(ctx.review)

      # The person's retry marker keeps the run; the review trigger is gone.
      assert %Run{status: :claimed, triggers: [%{"kind" => "retry", "auto" => false}]} =
               Repo.get!(Run, retry_id)

      assert request().status == :lapsed
    end
  end

  describe "规格运行的复核" do
    test "a new version while the review run is queued: obsolete when claimed", ctx do
      run = request!(ctx)
      {fe, _} = agent_run_scope(ctx.fe, ctx.task)

      {:ok, %{version: 3}} =
        TaskSpecs.submit_version(fe, ctx.ident, %{base_version: 2, files: spec_files(tag: "v3")})

      assert %ReviewRequest{status: :cancelled, close_reason: :superseded} = request()
      claimable!(ctx)
      claim!(ctx.review)
      assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, run.id)
    end

    test "spec triggers are not gated by dependencies" do
      refute Triggers.dependency_gated?([%{"kind" => "spec_decided"}])
      refute Triggers.dependency_gated?([%{"kind" => "spec_reviewed"}])
      refute Triggers.dependency_gated?([%{"kind" => "spec_review"}])
    end
  end
end
