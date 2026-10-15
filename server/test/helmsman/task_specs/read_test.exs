defmodule Helmsman.TaskSpecs.ReadTest do
  # add-spec-workflow 1.6: task-specs 「规格的读取、对比与通知」 (decisions 17, 22).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.{Events, TaskSpecs, Tx}

  setup do
    ctx = specs_fixture()
    Map.merge(ctx, %{ident: ctx.task.ident, bob_name: human_actor(ctx.workspace, ctx.bob).name})
  end

  defp submit(ctx, base, files, extra \\ %{}) do
    {:ok, %{version: n}} =
      TaskSpecs.submit_version(
        ctx.alice_scope,
        ctx.ident,
        Map.merge(%{base_version: base, files: files}, extra)
      )

    n
  end

  test "no spec: nil summary, not_found for the rest", ctx do
    assert {:ok, nil} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)
    assert {:error, {:spec, :not_found, ident}} = TaskSpecs.get(ctx.alice_scope, ctx.ident)
    assert ident == ctx.ident
    assert {:error, :not_found} = TaskSpecs.summary(ctx.alice_scope, "NOPE-1")
  end

  test "the summary", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 2)
    {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])
    {review, _} = agent_run_scope(ctx.qa, ctx.task)

    {:ok, _} =
      TaskSpecs.submit_review(review, ctx.ident, %{
        version: 2,
        verdict: "fail",
        issues: [
          %{severity: "P1", body: "a"},
          %{severity: "P2", body: "b"},
          %{severity: "P3", body: "c"}
        ]
      })

    assert {:ok, summary} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)

    assert %{
             status: :in_review,
             change_id: _,
             latest_version: 2,
             final_version: nil,
             mode: :approval,
             proposal: nil,
             pending_reviews: [%{n: 1, reviewer: "keel/review", version: 2}],
             unresolved: %{p1: 1, p2: 1, p3: 1},
             latest_valid: true
           } = summary
  end

  test "a version with some contents; the version list", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 2)

    assert {:ok,
            %{
              versions: [%{number: 1}, %{number: 2, valid: true, finalized: []}],
              version: version
            }} =
             TaskSpecs.get(ctx.alice_scope, ctx.ident, version: 1, files: ["tasks.md"])

    assert version.number == 1
    assert version.validation == %{valid: true, errors: []}

    assert Enum.map(version.files, & &1.path) == [
             "proposal.md",
             "specs/settings/spec.md",
             "tasks.md"
           ]

    assert Enum.find(version.files, &(&1.path == "tasks.md")).content =~ "Build the page"
    assert Enum.find(version.files, &(&1.path == "proposal.md")).content == nil
    assert Enum.all?(version.files, &(&1.bytes > 0))

    assert {:ok, %{version: %{files: files}}} =
             TaskSpecs.get(ctx.alice_scope, ctx.ident, files: [])

    assert Enum.all?(files, &is_nil(&1.content))

    assert {:error, {:spec, :version_not_found, 9}} =
             TaskSpecs.get(ctx.alice_scope, ctx.ident, version: 9)
  end

  test "an empty spec has no version", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 0)
    assert {:ok, %{versions: [], version: nil}} = TaskSpecs.get(ctx.alice_scope, ctx.ident)
  end

  test "diff of v1 and v3", ctx do
    files = Map.put(spec_files(), "design.md", "## Context\n\nx\n")
    submit(ctx, 0, files)
    submit(ctx, 1, %{"tasks.md" => "- [ ] other\n"})
    proposal = String.replace(files["proposal.md"], "Settings get lost.", "Settings vanish.")

    submit(
      ctx,
      2,
      %{"proposal.md" => proposal, "specs/api/spec.md" => spec_files()["specs/settings/spec.md"]},
      %{
        remove: ["design.md"]
      }
    )

    assert {:ok, %{from: 1, to: 3, files: diff, truncated: false}} =
             TaskSpecs.diff(ctx.alice_scope, ctx.ident, 1, 3)

    changes = Map.new(diff, &{&1.path, &1.change})

    assert changes == %{
             "design.md" => :removed,
             "proposal.md" => :modified,
             "specs/api/spec.md" => :added,
             "specs/settings/spec.md" => :unchanged,
             "tasks.md" => :modified
           }

    [hunk] = Enum.find(diff, &(&1.path == "proposal.md")).hunks
    assert Enum.count(hunk.lines, &(elem(&1, 0) == :del)) == 1
    assert Enum.count(hunk.lines, &(elem(&1, 0) == :ins)) == 1

    assert {:error, {:spec, :version_not_found, 4}} =
             TaskSpecs.diff(ctx.alice_scope, ctx.ident, 1, 4)
  end

  test "reviews, filtered by version and unresolved", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 2)
    {review, _} = agent_run_scope(ctx.review, ctx.task)

    {:ok, _} =
      TaskSpecs.submit_review(review, ctx.ident, %{
        version: 2,
        verdict: "fail",
        summary: "S",
        issues: [
          %{severity: "P1", file: "tasks.md", line: 1, anchor: "1.", body: "a", suggestion: "s"},
          %{severity: "P3", body: "b"}
        ]
      })

    {:ok, _} =
      TaskSpecs.add_note(ctx.alice_scope, ctx.ident, "R1.2", %{resolution: "accepted", body: "ok"})

    assert {:ok, %{requests: [], reviews: [r]}} = TaskSpecs.reviews(ctx.alice_scope, ctx.ident)
    assert %{number: 1, version: 2, reviewer: "keel/review", verdict: :fail, summary: "S"} = r
    assert r.reviewer_user_id == ctx.alice.id

    assert [
             %{
               ref: "R1.1",
               severity: :P1,
               file: "tasks.md",
               line: 1,
               resolution: :open,
               notes: []
             },
             %{
               ref: "R1.2",
               resolution: :accepted,
               notes: [%{n: 1, kind: :reply, resolution: :accepted}]
             }
           ] = r.issues

    assert {:ok, %{reviews: [%{issues: [%{ref: "R1.1"}]}]}} =
             TaskSpecs.reviews(ctx.alice_scope, ctx.ident, unresolved_only: true)

    assert {:ok, %{reviews: []}} = TaskSpecs.reviews(ctx.alice_scope, ctx.ident, version: 1)
  end

  test "events", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident)

    assert {:ok,
            [
              %{n: 1, action: "created", data: %{"change_id" => _}},
              %{n: 2, action: "version_submitted", version: 1}
            ]} =
             TaskSpecs.events(ctx.alice_scope, ctx.ident)
  end

  test "the to-do list", ctx do
    {_carol, viewer} = member_scope_fixture(ctx.workspace, :viewer)
    spec_fixture(ctx.alice_scope, ctx.ident)
    {lead, _} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})
    {:ok, _} = TaskSpecs.finalize(lead, ctx.ident, %{version: 1, summary: "ok"})

    other = task_fixture(ctx.alice_scope, ctx.project.key)
    spec_fixture(ctx.alice_scope, other.ident)
    {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, other.ident, [ctx.bob_name])

    assert {:ok, %{pending_approval: [approval], review_requests: [request]}} =
             TaskSpecs.attention(ctx.bob_scope)

    assert %{task: task_ident, version: 1, proposed_by: "keel/lead"} = approval
    assert task_ident == ctx.ident
    assert request.task == other.ident

    assert {:ok, %{pending_approval: [], review_requests: []}} = TaskSpecs.attention(viewer)
  end

  test "commits broadcast IDs; rollbacks and reads do not", ctx do
    Events.subscribe(Events.topic(:task, ctx.task.id))
    Events.subscribe(Events.topic(:workspace, ctx.workspace.id))
    task_id = ctx.task.id
    workspace_id = ctx.workspace.id

    spec_fixture(ctx.alice_scope, ctx.ident)
    assert_receive {:spec_changed, ^task_id}
    refute_receive {:spec_attention_changed, _}

    {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, [ctx.bob_name])
    assert_receive {:spec_changed, ^task_id}
    assert_receive {:spec_attention_changed, ^workspace_id}

    {:error, :rolled_back} =
      Tx.run(fn ->
        {:ok, _} = TaskSpecs.cancel_request(ctx.alice_scope, ctx.ident, %{reviewer: ctx.bob_name})
        {:error, :rolled_back}
      end)

    {:ok, _} = TaskSpecs.reviews(ctx.alice_scope, ctx.ident)
    refute_receive {:spec_changed, _}
    refute_receive {:spec_attention_changed, _}
  end
end
