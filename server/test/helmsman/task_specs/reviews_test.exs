defmodule Helmsman.TaskSpecs.ReviewsTest do
  # add-spec-workflow 1.4: task-specs 「评审请求」「提交评审」「问题的讨论与裁定」
  # (decision 5).
  use Helmsman.DataCase, async: true

  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Repo, TaskSpecs}
  alias Helmsman.TaskSpecs.{Issue, IssueNote, ReviewRequest, Spec}

  setup do
    ctx = specs_fixture()
    {fe, _} = agent_run_scope(ctx.fe, ctx.task)
    # v1 by alice, v2 by keel/fe.
    spec_fixture(ctx.alice_scope, ctx.task.ident)

    {:ok, %{version: 2}} =
      TaskSpecs.submit_version(fe, ctx.task.ident, %{
        base_version: 1,
        files: spec_files(tag: "v2")
      })

    {review, _} = agent_run_scope(ctx.review, ctx.task)
    {lead, _} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})

    Map.merge(ctx, %{
      ident: ctx.task.ident,
      fe_scope: fe,
      review_scope: review,
      lead_scope: lead,
      bob_name: human_actor(ctx.workspace, ctx.bob).name
    })
  end

  defp spec!(ctx), do: Repo.get_by!(Spec, task_id: ctx.task.id)

  defp review!(ctx, issues, verdict \\ "fail") do
    {:ok, %{review: n}} =
      TaskSpecs.submit_review(ctx.review_scope, ctx.ident, %{
        version: 2,
        verdict: verdict,
        summary: "Needs work",
        issues: issues
      })

    n
  end

  describe "评审请求" do
    test "a person asks a person and an agent", ctx do
      assert {:ok, %{requests: [bob, review]}} =
               TaskSpecs.request_reviews(
                 ctx.alice_scope,
                 ctx.ident,
                 [ctx.bob_name, "keel/review"],
                 %{
                   note: "Look at concurrency"
                 }
               )

      assert %{reviewer: _, request: 1, existing: false, dispatch: nil} = bob
      assert %{request: 2, existing: false, dispatch: %{result: :queued}} = review

      assert [%ReviewRequest{status: :requested}, %ReviewRequest{status: :requested}] =
               Repo.all(ReviewRequest)

      assert spec!(ctx).status == :in_review
    end

    test "asking again returns the pending request without another run", ctx do
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])
      runs = length(runs_of(ctx.task.id))

      assert {:ok, %{requests: [%{request: 1, existing: true, dispatch: nil}]}} =
               TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])

      assert length(runs_of(ctx.task.id)) == runs
      assert Repo.aggregate(ReviewRequest, :count) == 1
    end

    test "the author of the version cannot review it", ctx do
      assert {:error, {:spec, :own_version, "keel/fe"}} =
               TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/fe", "keel/review"])

      refute Repo.exists?(ReviewRequest)
    end

    test "squads, the system identity, unclaimed people and unknown names are not reviewers",
         ctx do
      Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :human, name: "ghost"})

      for name <- ["web-team", "helmsman", "ghost", "nobody"] do
        assert {:error, {:spec, :invalid_reviewer, ^name}} =
                 TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, [name])
      end
    end

    test "status errors", ctx do
      {:ok, %{decision: :proposed}} =
        TaskSpecs.finalize(ctx.lead_scope, ctx.ident, %{version: 2, summary: "ok"})

      assert {:error, {:spec, :pending_approval}} =
               TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])

      {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 2, wake: false})

      assert {:error, {:spec, :closed, :finalized}} =
               TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])
    end

    test "no version", ctx do
      other = Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, ctx.project.key)
      spec_fixture(ctx.alice_scope, other.ident, versions: 0)

      assert {:error, {:spec, :no_version}} =
               TaskSpecs.request_reviews(ctx.alice_scope, other.ident, ["keel/review"])
    end

    test "runs request reviews only through delegate", ctx do
      assert {:error, :forbidden} =
               TaskSpecs.request_reviews(ctx.lead_scope, ctx.ident, ["keel/review"])
    end

    test "the requester, a coordinator or a person cancels", ctx do
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])

      assert {:error, {:spec, :not_coordinator, _}} =
               TaskSpecs.cancel_request(ctx.fe_scope, ctx.ident, %{reviewer: "keel/review"})

      assert {:ok, %{request: 1}} =
               TaskSpecs.cancel_request(ctx.lead_scope, ctx.ident, %{reviewer: "keel/review"})

      assert %ReviewRequest{status: :cancelled, close_reason: :withdrawn} =
               Repo.one!(ReviewRequest)

      assert spec!(ctx).status == :draft

      assert {:error, {:spec, :request_not_found, 1}} =
               TaskSpecs.cancel_request(ctx.alice_scope, ctx.ident, %{request: 1})
    end
  end

  describe "提交评审" do
    test "a failing review completes the request", ctx do
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])

      n =
        review!(ctx, [
          %{severity: "P1", file: "specs/settings/spec.md", line: 3, body: "No failure scenario"},
          %{severity: "P3", body: "Wording"}
        ])

      assert n == 1

      assert [%Issue{number: 1, resolution: :open}, %Issue{number: 2, resolution: :open}] =
               Repo.all(from(i in Issue, order_by: i.number))

      assert %ReviewRequest{status: :submitted, review_id: review_id} = Repo.one!(ReviewRequest)
      assert is_integer(review_id)
      assert spec!(ctx).status == :draft
    end

    test "an older version is stale", ctx do
      assert {:error, {:spec, :stale_version, 2}} =
               TaskSpecs.submit_review(ctx.review_scope, ctx.ident, %{version: 1, verdict: "pass"})
    end

    test "the author cannot review", ctx do
      assert {:error, {:spec, :own_version, "keel/fe"}} =
               TaskSpecs.submit_review(ctx.fe_scope, ctx.ident, %{version: 2, verdict: "pass"})
    end

    test "issue locations must exist", ctx do
      assert {:error, {:spec, :invalid_issues, [%{index: 1}]}} =
               TaskSpecs.submit_review(ctx.review_scope, ctx.ident, %{
                 version: 2,
                 verdict: "fail",
                 issues: [%{severity: "P2", file: "specs/nope/spec.md", body: "x"}]
               })

      assert {:error, {:spec, :invalid_issues, [%{index: 1, message: message}]}} =
               TaskSpecs.submit_review(ctx.review_scope, ctx.ident, %{
                 version: 2,
                 verdict: "fail",
                 issues: [%{severity: "P2", file: "tasks.md", line: 99, body: "x"}]
               })

      assert message =~ "lines"
    end

    test "at most 100 issues", ctx do
      issues = for _ <- 1..101, do: %{severity: "P3", body: "x"}

      assert {:error, {:spec, :invalid_issues, _}} =
               TaskSpecs.submit_review(ctx.review_scope, ctx.ident, %{
                 version: 2,
                 verdict: "comment",
                 issues: issues
               })

      assert {:ok, %{review: 1}} =
               TaskSpecs.submit_review(ctx.review_scope, ctx.ident, %{
                 version: 2,
                 verdict: "comment",
                 issues: Enum.take(issues, 100)
               })
    end

    test "viewers cannot review", ctx do
      {_u, viewer} = member_scope_fixture(ctx.workspace, :viewer)

      assert {:error, :forbidden} =
               TaskSpecs.submit_review(viewer, ctx.ident, %{version: 2, verdict: "pass"})
    end
  end

  describe "问题的讨论与裁定" do
    setup ctx do
      review!(ctx, [
        %{severity: "P1", body: "Missing failure"},
        %{severity: "P3", body: "Wording"}
      ])

      :ok
    end

    test "the author disputes, the leader upholds", ctx do
      assert {:ok, %{resolution: :disputed}} =
               TaskSpecs.add_note(ctx.fe_scope, ctx.ident, "R1.1", %{
                 resolution: "disputed",
                 body: "The generic error page handles it"
               })

      assert {:ok, %{resolution: :upheld}} =
               TaskSpecs.add_note(ctx.lead_scope, ctx.ident, "R1.1", %{
                 resolution: "upheld",
                 body: "The settings page needs an inline message"
               })

      assert %Issue{resolution: :upheld} = Repo.get_by!(Issue, number: 1)

      assert [%IssueNote{kind: :reply, author_id: fe}, %IssueNote{kind: :ruling, author_id: lead}] =
               Repo.all(from(n in IssueNote, order_by: n.number))

      assert {fe, lead} == {ctx.fe.id, ctx.lead.id}
    end

    test "a delegated member cannot rule", ctx do
      assert {:error, {:spec, :not_coordinator, %{assignee: "web-team"}}} =
               TaskSpecs.add_note(ctx.fe_scope, ctx.ident, "R1.1", %{
                 resolution: "upheld",
                 body: "x"
               })
    end

    test "a resolved issue keeps its resolution; comments still work", ctx do
      {:ok, _} = TaskSpecs.add_note(ctx.fe_scope, ctx.ident, "R1.2", %{resolution: "accepted"})

      assert {:error, {:spec, :issue_resolved, "R1.2", :accepted}} =
               TaskSpecs.add_note(ctx.fe_scope, ctx.ident, "R1.2", %{
                 resolution: "disputed",
                 body: "x"
               })

      assert {:ok, %{resolution: :accepted, note: 2}} =
               TaskSpecs.add_note(ctx.fe_scope, ctx.ident, "R1.2", %{body: "Done in v3"})
    end

    test "disputed needs a reason", ctx do
      assert {:error, {:spec, :invalid_params, %{field: :body}}} =
               TaskSpecs.add_note(ctx.fe_scope, ctx.ident, "R1.1", %{resolution: "disputed"})
    end

    test "the reviewer cannot reply to its own issue", ctx do
      assert {:error, :forbidden} =
               TaskSpecs.add_note(ctx.review_scope, ctx.ident, "R1.1", %{resolution: "accepted"})
    end

    test "another identity of the reviewer's user withdraws", ctx do
      # keel/review belongs to alice.
      assert {:ok, %{resolution: :withdrawn}} =
               TaskSpecs.add_note(ctx.alice_scope, ctx.ident, "R1.1", %{resolution: "withdrawn"})

      assert {:error, :forbidden} =
               TaskSpecs.add_note(ctx.bob_scope, ctx.ident, "R1.2", %{resolution: "withdrawn"})
    end

    test "an unknown issue", ctx do
      assert {:error, {:spec, :issue_not_found, "R9.1"}} =
               TaskSpecs.add_note(ctx.alice_scope, ctx.ident, "R9.1", %{body: "x"})

      assert {:error, {:spec, :issue_not_found, "bogus"}} =
               TaskSpecs.add_note(ctx.alice_scope, ctx.ident, "bogus", %{body: "x"})
    end

    test "a closed spec takes no notes", ctx do
      {:ok, _} = TaskSpecs.abandon(ctx.alice_scope, ctx.ident, %{reason: "x"})

      assert {:error, {:spec, :closed, :abandoned}} =
               TaskSpecs.add_note(ctx.alice_scope, ctx.ident, "R1.1", %{body: "x"})
    end

    test "fixed_in_version only with accepted", ctx do
      assert {:error, {:spec, :invalid_params, %{field: :fixed_in_version}}} =
               TaskSpecs.add_note(ctx.fe_scope, ctx.ident, "R1.1", %{
                 resolution: "disputed",
                 body: "x",
                 fixed_in_version: 3
               })

      assert {:ok, _} =
               TaskSpecs.add_note(ctx.fe_scope, ctx.ident, "R1.1", %{
                 resolution: "accepted",
                 fixed_in_version: 3
               })
    end
  end
end
