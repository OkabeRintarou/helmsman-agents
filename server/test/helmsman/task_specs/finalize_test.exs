defmodule Helmsman.TaskSpecs.FinalizeTest do
  # add-spec-workflow 1.5: task-specs 「协调者」「定稿方式」「定稿与批准」
  # 「放弃与重新打开」「规格的权限」「规格的审计」 (decisions 6–8, 14).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.{Actors, Repo, Squads, Tasks, TaskSpecs}
  alias Helmsman.TaskSpecs.{Event, IssueNote, ReviewRequest, Spec, State, Version}

  setup do
    ctx = specs_fixture()
    spec_fixture(ctx.alice_scope, ctx.task.ident, versions: 3)
    {lead, _} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})
    {review, _} = agent_run_scope(ctx.review, ctx.task)
    {fe, _} = agent_run_scope(ctx.fe, ctx.task)
    Map.merge(ctx, %{ident: ctx.task.ident, lead_scope: lead, review_scope: review, fe_scope: fe})
  end

  defp spec!(ctx), do: Repo.get_by!(Spec, task_id: ctx.task.id)

  defp propose(ctx, version \\ 3),
    do: TaskSpecs.finalize(ctx.lead_scope, ctx.ident, %{version: version, summary: "R1 settled"})

  defp actions(ctx) do
    spec = spec!(ctx)

    Repo.all(
      from(e in Event,
        join: a in assoc(e, :actor),
        where: e.spec_id == ^spec.id,
        order_by: e.number,
        select: {e.action, a.name, e.version}
      )
    )
  end

  defp alice_name(ctx), do: human_actor(ctx.workspace, ctx.alice).name

  describe "协调者" do
    test "a leader run not as the squad is no coordinator", ctx do
      {plain, _} = agent_run_scope(ctx.lead, ctx.task)

      assert {:error, {:spec, :not_coordinator, %{assignee: "web-team", kind: :squad}}} =
               TaskSpecs.finalize(plain, ctx.ident, %{version: 3, summary: "x"})
    end

    test "a delegated member is no coordinator", ctx do
      assert {:error, {:spec, :not_coordinator, _}} =
               TaskSpecs.finalize(ctx.fe_scope, ctx.ident, %{version: 3, summary: "x"})

      assert {:error, {:spec, :not_coordinator, _}} =
               TaskSpecs.abandon(ctx.fe_scope, ctx.ident, %{reason: "x"})
    end

    test "an agent coordinator must summarize", ctx do
      assert {:error, {:spec, :invalid_params, %{field: :summary}}} =
               TaskSpecs.finalize(ctx.lead_scope, ctx.ident, %{version: 3})
    end
  end

  describe "定稿方式" do
    test "the squad's mode overrides the project's", ctx do
      {_u, admin} = member_scope_fixture(ctx.workspace, :admin)
      {:ok, _} = Squads.update(admin, "web-team", %{spec_finalize: "leader"})
      assert {:ok, %{mode: :leader}} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)
    end

    test "a single managed agent only proposes, even in leader mode", ctx do
      {:ok, _} =
        Helmsman.Projects.update(ctx.alice_scope, ctx.project.key, %{spec_finalize: "leader"})

      task = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/dev"})
      {:ok, task} = Tasks.get(ctx.alice_scope, task.ident)
      spec_fixture(ctx.alice_scope, task.ident)
      {dev, _} = agent_run_scope(ctx.agent, task)

      assert {:ok, %{decision: :proposed, spec: %{status: :pending_approval}}} =
               TaskSpecs.finalize(dev, task.ident, %{version: 1, summary: "ok"})
    end
  end

  describe "定稿与批准" do
    test "the leader proposes, a person approves", ctx do
      assert {:ok, %{decision: :proposed, spec: %{status: :pending_approval, proposal: proposal}}} =
               propose(ctx)

      assert %{version: 3, by: "keel/lead", summary: "R1 settled"} = proposal

      assert {:ok, %{decision: :approved, spec: %{status: :finalized, final_version: 3}}} =
               TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 3, wake: false})

      assert Enum.take(actions(ctx), -2) == [
               {"finalize_proposed", "keel/lead", 3},
               {"approved", alice_name(ctx), 3}
             ]
    end

    test "in leader mode the leader finalizes", ctx do
      {_u, admin} = member_scope_fixture(ctx.workspace, :admin)
      {:ok, _} = Squads.update(admin, "web-team", %{spec_finalize: "leader"})

      assert {:ok, %{decision: :finalized, spec: %{status: :finalized, final_version: 3}}} =
               propose(ctx)

      assert List.last(actions(ctx)) == {"finalized", "keel/lead", 3}
    end

    test "a person finalizes directly", ctx do
      assert {:ok, %{decision: :finalized}} =
               TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 3, wake: false})
    end

    test "an unresolved P1 blocks; a P3 does not", ctx do
      {:ok, _} =
        TaskSpecs.submit_review(ctx.review_scope, ctx.ident, %{
          version: 3,
          verdict: "fail",
          issues: [%{severity: "P1", body: "a"}, %{severity: "P3", body: "b"}]
        })

      {:ok, _} =
        TaskSpecs.add_note(ctx.fe_scope, ctx.ident, "R1.1", %{resolution: "disputed", body: "no"})

      assert {:error, {:spec, :unresolved_issues, ["R1.1"]}} = propose(ctx)
      assert spec!(ctx).status == :draft

      {:ok, _} =
        TaskSpecs.add_note(ctx.lead_scope, ctx.ident, "R1.1", %{resolution: "upheld", body: "fix"})

      assert {:ok, %{decision: :proposed}} = propose(ctx)
    end

    test "pending requests block", ctx do
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])
      assert {:error, {:spec, :reviews_pending, ["keel/review"]}} = propose(ctx)
    end

    test "an invalid version cannot be finalized", ctx do
      {:ok, %{version: 4}} =
        TaskSpecs.submit_version(ctx.alice_scope, ctx.ident, %{
          base_version: 3,
          files: %{"tasks.md" => "Nothing to tick"}
        })

      assert {:error, {:spec, :invalid, [%{rule: "tasks_no_items"}]}} =
               TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 4})
    end

    test "an older version is stale", ctx do
      assert {:error, {:spec, :stale_version, 3}} =
               TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 2})
    end

    test "an external agent assignee only proposes, even of an owner", ctx do
      {:ok, ext} = Actors.identify(ctx.alice_scope, %{name: "claude-desktop"})
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "claude-desktop"})
      spec_fixture(ctx.alice_scope, task.ident)
      scope = %{ctx.alice_scope | actor: ext, via: :api}

      assert {:ok, %{decision: :proposed, spec: %{status: :pending_approval}}} =
               TaskSpecs.finalize(scope, task.ident, %{version: 1, summary: "done"})

      assert {:error, :forbidden} = TaskSpecs.reject(scope, task.ident, %{reason: "x"})
    end

    test "a person sends the proposal back", ctx do
      assert {:error, {:spec, :no_proposal}} =
               TaskSpecs.reject(ctx.alice_scope, ctx.ident, %{reason: "x", wake: false})

      {:ok, _} = propose(ctx)

      assert {:error, :forbidden} = TaskSpecs.reject(ctx.lead_scope, ctx.ident, %{reason: "x"})

      assert {:error, {:spec, :invalid_params, %{field: :reason}}} =
               TaskSpecs.reject(ctx.alice_scope, ctx.ident, %{wake: false})

      assert {:ok, %{spec: %{status: :draft, proposal: nil}}} =
               TaskSpecs.reject(ctx.alice_scope, ctx.ident, %{
                 reason: "Missing errors",
                 wake: false
               })

      assert %Event{data: %{"reason" => "Missing errors"}, version: 3} =
               Repo.get_by!(Event, action: "proposal_rejected")
    end

    test "proposing twice", ctx do
      {:ok, _} = propose(ctx)
      assert {:error, {:spec, :pending_approval}} = propose(ctx)
    end
  end

  describe "放弃与重新打开" do
    test "abandoning cancels the requests and withdraws the proposal", ctx do
      {:ok, _} = propose(ctx)

      assert {:ok, %{status: :abandoned}} =
               TaskSpecs.abandon(ctx.alice_scope, ctx.ident, %{reason: "Not needed"})

      assert Enum.take(actions(ctx), -2) |> Enum.map(&elem(&1, 0)) ==
               ["proposal_withdrawn", "abandoned"]

      {:ok, _} = TaskSpecs.reopen(ctx.alice_scope, ctx.ident, %{reason: "Needed after all"})
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])
      {:ok, _} = TaskSpecs.abandon(ctx.lead_scope, ctx.ident, %{reason: "Again"})

      assert %ReviewRequest{status: :cancelled, close_reason: :abandoned} =
               Repo.one!(ReviewRequest)
    end

    test "reopening a finalized spec keeps the version marked", ctx do
      {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 3, wake: false})

      assert {:ok, %{status: :draft, final_version: nil}} =
               TaskSpecs.reopen(ctx.alice_scope, ctx.ident, %{reason: "Gap"})

      spec = spec!(ctx)
      assert {spec.status, spec.final_version} == {:draft, nil}

      {:ok, %{versions: versions}} = TaskSpecs.get(ctx.alice_scope, ctx.ident)
      assert [%{by: _}] = Enum.find(versions, &(&1.number == 3)).finalized

      assert {:ok, %{version: 4}} =
               TaskSpecs.submit_version(ctx.alice_scope, ctx.ident, %{
                 base_version: 3,
                 files: spec_files(tag: "v4")
               })
    end

    test "only closed specs reopen; reasons are required", ctx do
      assert {:error, {:spec, :not_closed, :draft}} =
               TaskSpecs.reopen(ctx.alice_scope, ctx.ident, %{reason: "x"})

      assert {:error, {:spec, :invalid_params, %{field: :reason}}} =
               TaskSpecs.abandon(ctx.alice_scope, ctx.ident, %{})
    end
  end

  describe "规格的权限" do
    test "viewers read but do not write", ctx do
      {_u, viewer} = member_scope_fixture(ctx.workspace, :viewer)
      assert {:ok, %{latest_version: 3}} = TaskSpecs.summary(viewer, ctx.ident)
      assert {:error, :forbidden} = TaskSpecs.finalize(viewer, ctx.ident, %{version: 3})
      assert {:error, :forbidden} = TaskSpecs.abandon(viewer, ctx.ident, %{reason: "x"})

      assert {:error, :forbidden} =
               TaskSpecs.submit_review(viewer, ctx.ident, %{version: 3, verdict: "pass"})
    end

    test "a run writes only its own task's spec", ctx do
      other = task_fixture(ctx.alice_scope, ctx.project.key)

      assert {:error, :forbidden} =
               TaskSpecs.submit_version(ctx.fe_scope, other.ident, %{
                 base_version: 0,
                 files: spec_files()
               })

      # Any run reads.
      spec_fixture(ctx.alice_scope, other.ident)
      assert {:ok, %{latest_version: 1}} = TaskSpecs.summary(ctx.fe_scope, other.ident)
    end

    test "permissions for buttons", ctx do
      {:ok, perms} = TaskSpecs.permissions(ctx.alice_scope, ctx.ident)
      assert perms.write and perms.approve and perms.rule and perms.abandon
      refute perms.reject or perms.reopen or perms.propose

      {:ok, perms} = TaskSpecs.permissions(ctx.lead_scope, ctx.ident)
      assert perms.propose and perms.rule
      refute perms.approve or perms.request_review

      {:ok, perms} = TaskSpecs.permissions(ctx.fe_scope, ctx.ident)
      assert perms.write
      refute perms.propose or perms.rule or perms.abandon

      other = task_fixture(ctx.alice_scope, ctx.project.key)

      assert {:ok, %{write: true, approve: false}} =
               TaskSpecs.permissions(ctx.alice_scope, other.ident)
    end
  end

  describe "规格的审计" do
    test "the documented sequence replays to the rows", ctx do
      # v1..v3 exist; two requests on v3: one submitted, one lapsed.
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review", "keel/qa"])

      {:ok, _} =
        TaskSpecs.submit_review(ctx.review_scope, ctx.ident, %{version: 3, verdict: "pass"})

      run =
        run_fixture(ctx.qa, %{
          task_id: ctx.task.id,
          status: :succeeded,
          lane: :reply,
          triggers: [%{"kind" => "spec_review", "spec_request" => 2}]
        })

      :ok = TaskSpecs.settle_run(run.id)
      {:ok, _} = propose(ctx)
      {:ok, _} = TaskSpecs.reject(ctx.alice_scope, ctx.ident, %{reason: "no", wake: false})

      {:ok, _} =
        TaskSpecs.submit_version(ctx.fe_scope, ctx.ident, %{
          base_version: 3,
          files: spec_files(tag: "v4")
        })

      versions_before = Repo.all(from(v in Version, order_by: v.number))
      {:ok, _} = propose(ctx, 4)
      {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 4, wake: false})
      {:ok, _} = TaskSpecs.reopen(ctx.alice_scope, ctx.ident, %{reason: "gap"})

      assert Repo.all(from(v in Version, order_by: v.number)) == versions_before

      spec = spec!(ctx)

      events =
        Repo.all(from(e in Event, where: e.spec_id == ^spec.id)) |> Enum.map(&Map.from_struct/1)

      replay = State.replay(events, Repo.all(IssueNote))

      assert replay.spec.status == spec.status
      assert replay.spec.final_version == spec.final_version
      assert replay.spec.proposal == nil

      assert %{1 => %{status: :submitted, review: 1}, 2 => %{status: :lapsed}} = replay.requests

      assert Repo.all(from(r in ReviewRequest, order_by: r.number, select: r.status)) == [
               :submitted,
               :lapsed
             ]

      {:ok, %{versions: versions}} = TaskSpecs.get(ctx.alice_scope, ctx.ident)
      assert [%{by: by}] = Enum.find(versions, &(&1.number == 4)).finalized
      assert by == alice_name(ctx)
    end
  end
end
