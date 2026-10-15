defmodule Helmsman.TaskSpecs.DelegateSpecTest do
  # add-spec-workflow 2.1: spec-dispatch 「规格委派」 (decision 9).
  use Helmsman.DataCase, async: true

  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.{Repo, Squads, TaskSpecs}
  alias Helmsman.Runs.Run
  alias Helmsman.TaskSpecs.{ReviewRequest, Spec}
  alias HelmsmanMCP.{Context, ErrorText}

  setup do
    ctx = specs_fixture()
    {lead, lead_run} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})
    {fe, _} = agent_run_scope(ctx.fe, ctx.task)

    Map.merge(ctx, %{
      ident: ctx.task.ident,
      lead_scope: lead,
      lead_run: lead_run,
      fe_scope: fe,
      bob_name: human_actor(ctx.workspace, ctx.bob).name
    })
  end

  # v1 by alice, v2 by keel/fe.
  defp two_versions(ctx) do
    spec_fixture(ctx.alice_scope, ctx.ident)

    {:ok, %{version: 2}} =
      TaskSpecs.submit_version(ctx.fe_scope, ctx.ident, %{
        base_version: 1,
        files: spec_files(tag: "v2")
      })
  end

  defp delegate(ctx, to, spec, scope \\ nil),
    do: Squads.delegate(scope || ctx.lead_scope, ctx.ident, to, "Do the spec part", spec)

  defp member_runs(ctx, agent),
    do:
      Repo.all(
        from(r in Run,
          where: r.task_id == ^ctx.task.id and r.agent_id == ^agent.id and r.status == :queued
        )
      )

  test "delegating the draft", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 0)
    assert {:ok, %{result: :queued}} = delegate(ctx, "keel/fe", "draft")

    assert [%Run{triggers: [trigger]}] = member_runs(ctx, ctx.fe)
    assert %{"kind" => "delegated", "spec_role" => "draft"} = trigger
    refute Map.has_key?(trigger, "spec_request")
  end

  test "delegating a review: a run and a request", ctx do
    two_versions(ctx)
    assert {:ok, %{result: :queued, request: 1}} = delegate(ctx, "keel/review", "review")

    assert [%Run{triggers: [trigger]} = run] = member_runs(ctx, ctx.review)
    assert %{"spec_role" => "review", "spec_request" => 1, "spec_version" => 2} = trigger

    # The run read model carries the spec fields (界面契约 R7).
    assert [%{kind: "delegated", spec_role: "review", spec_request: 1, spec_version: 2} = view] =
             Helmsman.Runs.summary(run).triggers

    refute Map.has_key?(view, :verdict)

    assert %ReviewRequest{status: :requested, request_run_id: run_id, requested_by_id: by} =
             Repo.one!(ReviewRequest)

    assert {run_id, by} == {ctx.lead_run.id, ctx.lead.id}
    assert Repo.get_by!(Spec, task_id: ctx.task.id).status == :in_review
  end

  test "a person member gets only a request", ctx do
    two_versions(ctx)
    runs = length(runs_of(ctx.task.id))
    name = ctx.bob_name

    assert {:ok, %{result: :requested, reviewer: ^name, request: 1}} =
             delegate(ctx, name, "review")

    assert length(runs_of(ctx.task.id)) == runs
    assert %ReviewRequest{status: :requested} = Repo.one!(ReviewRequest)

    # Without the review role a person is still no delegate.
    assert {:error, {:delegate, :person_member, ^name}} = delegate(ctx, name, "revise")
  end

  test "a pending request of the member: review_pending, nothing written", ctx do
    two_versions(ctx)
    {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])
    runs = length(runs_of(ctx.task.id))

    assert {:error, {:spec, :review_pending, %{reviewer: "keel/review", request: 1}} = reason} =
             delegate(ctx, "keel/review", "review")

    assert Repo.aggregate(ReviewRequest, :count) == 1
    assert length(runs_of(ctx.task.id)) == runs

    alice = human_actor(ctx.workspace, ctx.alice).name
    context = %Context{scope: ctx.lead_scope, tool: "delegate", args: %{"task_id" => ctx.ident}}

    assert ErrorText.format(reason, context) ==
             {:ok,
              "keel/review already has a pending review request R1 on version 2 (requested " <>
                "by #{alice}). Wait for it, or cancel_spec_review(\"#{ctx.ident}\", " <>
                "\"keel/review\") and delegate again."}
  end

  test "the same applies to a person member's pending request", ctx do
    two_versions(ctx)
    {:ok, _} = delegate(ctx, ctx.bob_name, "review")
    assert {:error, {:spec, :review_pending, _}} = delegate(ctx, ctx.bob_name, "review")
  end

  test "spec checks come first", ctx do
    assert {:error, {:spec, :invalid_params, %{field: :spec}}} = delegate(ctx, "keel/fe", "x")
    assert {:error, {:spec, :no_version}} = delegate(ctx, "keel/fe", "revise")
    assert {:error, {:spec, :no_version}} = delegate(ctx, "nobody", "review")

    two_versions(ctx)
    assert {:error, {:spec, :own_version, "keel/fe"}} = delegate(ctx, "keel/fe", "review")

    {:ok, _} = TaskSpecs.finalize(ctx.lead_scope, ctx.ident, %{version: 2, summary: "ok"})
    assert {:error, {:spec, :pending_approval}} = delegate(ctx, "keel/review", "review")
    assert {:ok, _} = delegate(ctx, "keel/fe", "revise")

    {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 2, wake: false})
    assert {:error, {:spec, :closed, :finalized}} = delegate(ctx, "keel/fe", "revise")
  end

  test "not dispatched: no request", ctx do
    two_versions(ctx)

    # The authorization source may not trigger keel/qa (alice's, owner_only).
    {carol_lead, _} =
      agent_run_scope(ctx.lead, ctx.task, %{
        squad_id: ctx.squad.id,
        root_initiator_user_id: ctx.carol.id
      })

    assert {:ok, %{result: :skipped, reason: :unauthorized}} =
             delegate(ctx, "keel/qa", "review", carol_lead)

    refute Repo.exists?(ReviewRequest)
    assert Repo.get_by!(Spec, task_id: ctx.task.id).status == :draft
  end

  test "a refused chain: no request", ctx do
    two_versions(ctx)

    {looped, _} =
      agent_run_scope(ctx.lead, ctx.task, %{
        squad_id: ctx.squad.id,
        causal_agent_ids: [ctx.review.id, ctx.lead.id]
      })

    assert {:ok, %{result: :skipped, reason: :loop_detected}} =
             delegate(ctx, "keel/review", "review", looped)

    refute Repo.exists?(ReviewRequest)
  end
end
