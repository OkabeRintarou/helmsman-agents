defmodule HelmsmanMCP.Tools.SpecToolsTest do
  # add-spec-workflow 3.1: the spec tools over /mcp with run tokens and an
  # hm_ token (spec-tools, decision 20). The anubis session processes are
  # not children of the test process: the sandbox runs in shared mode.
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.ApiTokensFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.Repo
  alias Helmsman.TaskSpecs
  alias Helmsman.TaskSpecs.Version
  alias HelmsmanMCP.{Context, ErrorText, Resources}
  alias HelmsmanWeb.MCPClient

  @read_tools ~w(get_spec diff_spec list_spec_reviews)
  @write_tools ~w(submit_spec_version submit_spec_review reply_spec_issue rule_spec_issue
                  finalize_spec update_spec cancel_spec_review)

  setup do
    ctx = specs_fixture()
    %{token: token} = api_token_fixture(ctx.alice_scope)
    Map.merge(ctx, %{ident: ctx.task.ident, token: token})
  end

  defp run_token(agent, task, caps, attrs \\ %{}) do
    run =
      run_fixture(
        agent,
        Map.merge(%{task_id: task.id, status: :running, capabilities: caps}, attrs)
      )

    {_scope, token} = run_scope_fixture(run)
    {token, run}
  end

  defp session(token), do: {token, MCPClient.handshake(token)}

  defp call({token, sid}, tool, args), do: MCPClient.call_tool(token, sid, tool, args)

  defp names({token, sid}) do
    resp = MCPClient.rpc(token, sid, "tools/list")
    200 = resp.status
    Enum.map(Jason.decode!(resp.body)["result"]["tools"], & &1["name"])
  end

  defp files(map), do: for({path, content} <- map, do: %{path: path, content: content})

  test "tools/list by caller", ctx do
    names = names(session(ctx.token))
    assert Enum.all?(@read_tools ++ @write_tools ++ ["request_spec_review"], &(&1 in names))

    {writer, _} = run_token(ctx.fe, ctx.task, ["read", "write_task"])
    names = names(session(writer))
    assert Enum.all?(@read_tools ++ @write_tools, &(&1 in names))
    refute "request_spec_review" in names

    {reader, _} = run_token(ctx.fe, nil_task(ctx), ["read"])
    names = names(session(reader))
    assert Enum.all?(@read_tools, &(&1 in names))
    assert Enum.filter(@write_tools ++ ["request_spec_review"], &(&1 in names)) == []
  end

  # A run-only automation without a task.
  defp nil_task(_ctx), do: %{id: nil}

  test "a run submits a version: author and source run", ctx do
    {token, run} = run_token(ctx.fe, ctx.task, ["read", "write_task"])

    assert {:ok, %{"version" => 1, "validation" => %{"valid" => true}, "files" => listed}} =
             call(session(token), "submit_spec_version", %{
               task_id: ctx.ident,
               base_version: 0,
               files: files(spec_files()),
               change_id: "add-settings-page"
             })

    assert Enum.map(listed, & &1["path"]) == ["proposal.md", "specs/settings/spec.md", "tasks.md"]
    version = Repo.get_by!(Version, number: 1) |> Repo.preload(:author)
    assert version.author.name == "keel/fe"
    assert version.source_run_id == run.id

    assert {:ok, %{change_id: "add-settings-page"}} =
             TaskSpecs.summary(ctx.alice_scope, ctx.ident)
  end

  test "a version that fails validation says it is a draft", ctx do
    assert {:ok, %{"version" => 1, "validation" => %{"valid" => false}, "hint" => hint}} =
             call(session(ctx.token), "submit_spec_version", %{
               task_id: ctx.ident,
               base_version: 0,
               files: files(spec_files(invalid: true))
             })

    assert hint =~ "draft"
  end

  test "a stale base_version names the latest and diff_spec", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 3)

    assert {:error, text} =
             call(session(ctx.token), "submit_spec_version", %{
               task_id: ctx.ident,
               base_version: 2,
               files: files(%{"design.md" => "## Context\n\nx\n"})
             })

    assert text ==
             "The latest version is 3, not 2. Read the changes with diff_spec(\"#{ctx.ident}\", " <>
               "2, 3) and resubmit with base_version: 3."
  end

  test "get_spec of a large version lists the files; files reads them", ctx do
    big = fn tag -> spec_files(tag: tag <> String.duplicate("x", 100 * 1024)) end

    files =
      Map.merge(spec_files(), %{
        "specs/a/spec.md" => big.("a")["specs/settings/spec.md"],
        "specs/b/spec.md" => big.("b")["specs/settings/spec.md"],
        "specs/c/spec.md" => big.("c")["specs/settings/spec.md"],
        "specs/d/spec.md" => big.("d")["specs/settings/spec.md"]
      })

    spec_fixture(ctx.alice_scope, ctx.ident, files: files)
    mcp = session(ctx.token)

    assert {:ok, %{"version" => %{"files" => listed, "truncated" => note}}} =
             call(mcp, "get_spec", %{task_id: ctx.ident})

    assert length(listed) == 7
    refute Enum.any?(listed, &Map.has_key?(&1, "content"))
    assert note =~ "files"

    assert {:ok, %{"version" => %{"files" => listed} = version}} =
             call(mcp, "get_spec", %{task_id: ctx.ident, files: ["proposal.md"]})

    refute Map.has_key?(version, "truncated")

    assert [%{"path" => "proposal.md", "content" => content}] =
             Enum.filter(listed, & &1["content"])

    assert content == spec_files()["proposal.md"]
  end

  test "get_spec, diff_spec and list_spec_reviews for a read-only run", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 2)
    {token, _} = run_token(ctx.qa, ctx.task, ["read"])
    mcp = session(token)

    assert {:ok, %{"spec" => %{"latest_version" => 2}, "versions" => [_, _], "version" => v}} =
             call(mcp, "get_spec", %{task_id: ctx.ident, version: 1})

    assert v["number"] == 1
    assert Enum.all?(v["files"], &is_binary(&1["content"]))

    assert {:ok, %{"from" => 1, "to" => 2, "files" => diffed}} =
             call(mcp, "diff_spec", %{task_id: ctx.ident, from: 1})

    proposal = Enum.find(diffed, &(&1["path"] == "proposal.md"))
    assert proposal["change"] == "modified"
    assert proposal["diff"] =~ "@@ -1,"
    assert proposal["diff"] =~ "\n+Settings get lost. v2\n"

    assert {:ok, %{"requests" => [], "reviews" => []}} =
             call(mcp, "list_spec_reviews", %{task_id: ctx.ident})

    assert {:error, text} =
             call(mcp, "submit_spec_version", %{task_id: ctx.ident, base_version: 2})

    assert text =~ "This run can only read"
  end

  test "no spec yet", ctx do
    assert {:error, text} = call(session(ctx.token), "get_spec", %{task_id: ctx.ident})

    assert text ==
             "#{ctx.ident} has no spec yet. Create it with submit_spec_version(task_id: " <>
               "\"#{ctx.ident}\", base_version: 0, files: [...])."
  end

  test "review, reply, rule, finalize and approve", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident)
    {review, _} = run_token(ctx.review, ctx.task, ["read", "write_task"])
    {fe, _} = run_token(ctx.fe, ctx.task, ["read", "write_task"])

    {lead, _} =
      run_token(ctx.lead, ctx.task, ["read", "write_task", "delegate"], %{squad_id: ctx.squad.id})

    alice = session(ctx.token)
    lead = session(lead)

    assert {:ok, %{"review" => 1, "issues" => ["R1.1", "R1.2"]}} =
             call(session(review), "submit_spec_review", %{
               task_id: ctx.ident,
               version: 1,
               verdict: "fail",
               summary: "Unclear.",
               issues: [
                 %{severity: "P1", file: "proposal.md", line: 1, body: "Why?"},
                 %{severity: "P3", body: "Nit."}
               ]
             })

    assert {:error, text} =
             call(lead, "finalize_spec", %{task_id: ctx.ident, version: 1, summary: "Done"})

    assert text ==
             "Unresolved P1/P2 issues: R1.1. Reply with reply_spec_issue or rule with " <>
               "rule_spec_issue first."

    fe = session(fe)

    assert {:ok, %{"ref" => "R1.1", "resolution" => "disputed"}} =
             call(fe, "reply_spec_issue", %{
               task_id: ctx.ident,
               issue: "R1.1",
               resolution: "disputed",
               body: "It is in the summary."
             })

    assert {:error, text} =
             call(fe, "reply_spec_issue", %{
               task_id: ctx.ident,
               issue: "R1.1",
               resolution: "upheld",
               body: "x"
             })

    assert text ==
             "resolution must be accepted, disputed or withdrawn (rulings use rule_spec_issue)."

    assert {:ok, %{"resolution" => "dismissed"}} =
             call(lead, "rule_spec_issue", %{
               task_id: ctx.ident,
               issue: "R1.1",
               ruling: "dismissed",
               reason: "Covered."
             })

    assert {:error, text} =
             call(lead, "rule_spec_issue", %{
               task_id: ctx.ident,
               issue: "R1.1",
               ruling: "upheld",
               reason: "x"
             })

    assert text ==
             "R1.1 is already dismissed; you can still add a comment (reply_spec_issue without " <>
               "resolution)."

    assert {:error, text} =
             call(fe, "rule_spec_issue", %{
               task_id: ctx.ident,
               issue: "R1.2",
               ruling: "upheld",
               reason: "x"
             })

    assert text ==
             "Only the leader of web-team (in a run as the squad) or a person can do this on " <>
               "#{ctx.ident}."

    assert {:ok, %{"status" => "pending_approval", "decision" => "proposed"}} =
             call(lead, "finalize_spec", %{task_id: ctx.ident, version: 1, summary: "Settled"})

    # A person approves over REST (spec_controller_test); MCP writes as agents.
    assert {:ok, %{decision: :approved}} =
             TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 1, wake: false})

    assert {:error, text} =
             call(fe, "submit_spec_version", %{
               task_id: ctx.ident,
               base_version: 1,
               files: files(%{"design.md" => "x"})
             })

    assert text ==
             "The spec of #{ctx.ident} is finalized; ask a person or the squad leader to reopen " <>
               "it (update_spec status: \"draft\")."

    assert {:error, text} =
             call(alice, "update_spec", %{task_id: ctx.ident, status: "draft", reason: "x"})

    assert text =~ "Only the leader of web-team"

    assert {:ok, %{"status" => "draft", "final_version" => nil}} =
             call(lead, "update_spec", %{task_id: ctx.ident, status: "draft", reason: "More"})
  end

  test "request_spec_review: a person's token requests, a run cannot", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident)

    {token, _} =
      run_token(ctx.lead, ctx.task, ["read", "write_task", "delegate"], %{squad_id: ctx.squad.id})

    assert {:error, text} =
             call(session(token), "request_spec_review", %{
               task_id: ctx.ident,
               reviewers: ["keel/review"]
             })

    assert text =~ "delegate"
    assert text =~ "mention"

    # An hm_ token writes as an agent: alice/cli coordinates the task it is assigned.
    agent_fixture(ctx.workspace, ctx.alice, "alice/cli")
    task = Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Helmsman.Tasks.update(ctx.alice_scope, task.ident, %{assignee: "alice/cli"})
    spec_fixture(ctx.alice_scope, task.ident)
    alice = session(ctx.token)
    args = %{task_id: task.ident, reviewers: ["keel/review"], actor: "alice/cli"}

    assert {:ok, %{"requests" => [%{"reviewer" => "keel/review", "request" => 1} = request]}} =
             call(alice, "request_spec_review", Map.put(args, :instructions, "Check it."))

    assert %{"existing" => false, "dispatch" => %{"result" => "queued"}} = request

    assert {:ok, %{"requests" => [%{"request" => 1, "existing" => true, "dispatch" => nil}]}} =
             call(alice, "request_spec_review", args)

    assert {:ok, %{"request" => 1, "spec" => %{"pending_reviews" => []}}} =
             call(alice, "cancel_spec_review", %{
               task_id: task.ident,
               reviewer: "keel/review",
               actor: "alice/cli"
             })
  end

  test "update_spec creates an empty spec; own_version", ctx do
    alice = session(ctx.token)

    assert {:ok, %{"change_id" => "add-x", "latest_version" => 0, "status" => "draft"}} =
             call(alice, "update_spec", %{task_id: ctx.ident, change_id: "add-x"})

    {fe, _} = run_token(ctx.fe, ctx.task, ["read", "write_task"])
    fe = session(fe)

    {:ok, %{"version" => 1}} =
      call(fe, "submit_spec_version", %{
        task_id: ctx.ident,
        base_version: 0,
        files: files(spec_files())
      })

    assert {:error, text} =
             call(fe, "submit_spec_review", %{
               task_id: ctx.ident,
               version: 1,
               verdict: "pass",
               summary: "Fine"
             })

    assert text == "keel/fe wrote the latest version and cannot review it. Pick another reviewer."
  end

  test "get_task and helmsman://tasks/{id} summarize the spec", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 2, change_id: "add-settings-page")
    {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])
    {qa, _} = agent_run_scope(ctx.qa, ctx.task)

    {:ok, _} =
      TaskSpecs.submit_review(qa, ctx.ident, %{
        version: 2,
        verdict: "fail",
        summary: "No.",
        issues: [%{severity: "P1", body: "Missing."}]
      })

    assert {:ok, %{"spec" => spec}} = call(session(ctx.token), "get_task", %{task_id: ctx.ident})

    assert spec == %{
             "change_id" => "add-settings-page",
             "status" => "in_review",
             "latest_version" => 2,
             "final_version" => nil,
             "finalize_mode" => "approval",
             "unresolved_issues" => 1,
             "pending_reviews" => 1
           }

    other = Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, ctx.project.key)
    assert {:ok, %{"spec" => nil}} = call(session(ctx.token), "get_task", %{task_id: other.ident})

    mcp_ctx = %Context{tool: nil, args: %{}, scope: ctx.alice_scope, session: nil}
    {:ok, markdown} = Resources.read("helmsman://tasks/" <> ctx.ident, mcp_ctx)

    assert markdown =~
             "- Spec: add-settings-page, in_review, latest v2, final none, 1 unresolved issues, " <>
               "1 pending reviews (get_spec)\n"

    {:ok, markdown} = Resources.read("helmsman://tasks/" <> other.ident, mcp_ctx)
    refute markdown =~ "- Spec:"
  end

  # Decision 20: the text of every spec error.
  @texts [
    {{:spec, :not_found, "BOS-12"},
     "BOS-12 has no spec yet. Create it with submit_spec_version(task_id: \"BOS-12\", " <>
       "base_version: 0, files: [...])."},
    {{:spec, :stale_version, 3},
     "The latest version is 3, not 2. Read the changes with diff_spec(\"BOS-12\", 2, 3) and " <>
       "resubmit with base_version: 3."},
    {{:spec, :closed, :finalized},
     "The spec of BOS-12 is finalized; ask a person or the squad leader to reopen it " <>
       "(update_spec status: \"draft\")."},
    {{:spec, :not_closed, :draft},
     "The spec of BOS-12 is draft: only a finalized or abandoned spec reopens."},
    {{:spec, :no_changes}, "Nothing changed compared with version 2."},
    {{:spec, :no_version},
     "The spec of BOS-12 has no version yet. Submit one with submit_spec_version (or " <>
       "delegate(..., spec: \"draft\")) first."},
    {{:spec, :pending_approval},
     "The spec of BOS-12 is waiting for a person's approval. Wait for the decision; a new " <>
       "version withdraws the proposal."},
    {{:spec, :no_proposal}, "The spec of BOS-12 has no proposal waiting for approval."},
    {{:spec, :invalid,
      [
        %{file: "tasks.md", line: nil, rule: "missing_tasks", message: "tasks.md is missing"},
        %{file: "specs/a/spec.md", line: 4, rule: "requirement_no_scenario", message: "x"}
      ]},
     "Version 3 does not pass validation: tasks.md missing_tasks tasks.md is missing; " <>
       "specs/a/spec.md:4 requirement_no_scenario x. Fix it and submit a new version."},
    {{:spec, :unresolved_issues, ["R2.1", "R2.3"]},
     "Unresolved P1/P2 issues: R2.1, R2.3. Reply with reply_spec_issue or rule with " <>
       "rule_spec_issue first."},
    {{:spec, :reviews_pending, ["keel/review"]},
     "Reviews still pending on version 3 from keel/review. Wait for them or cancel_spec_review."},
    {{:spec, :not_coordinator, %{task: "BOS-12", assignee: "web-team", kind: :squad}},
     "Only the leader of web-team (in a run as the squad) or a person can do this on BOS-12."},
    {{:spec, :review_pending,
      %{reviewer: "keel/review", request: 3, requested_by: "alice", version: 2}},
     "keel/review already has a pending review request R3 on version 2 (requested by alice). " <>
       "Wait for it, or cancel_spec_review(\"BOS-12\", \"keel/review\") and delegate again."},
    {{:spec, :own_version, "keel/fe"},
     "keel/fe wrote the latest version and cannot review it. Pick another reviewer."},
    {{:spec, :invalid_reviewer, "web-team"},
     "web-team cannot review: a reviewer is a person who joined the workspace or an agent " <>
       "(not a squad or the system)."},
    {{:spec, :issue_resolved, "R2.1", :upheld},
     "R2.1 is already upheld; you can still add a comment (reply_spec_issue without " <>
       "resolution)."},
    {{:spec, :issue_not_found, "R9.1"},
     "There is no issue R9.1 on BOS-12; list_spec_reviews shows them (R<n>.<i>)."},
    {{:spec, :version_not_found, 9},
     "BOS-12 has no spec version 9; get_spec lists the versions."},
    {{:spec, :invalid_files, [%{path: "x.md", message: "is not an allowed path"}]},
     "Invalid files: x.md: is not an allowed path. Paths: proposal.md, design.md, tasks.md, " <>
       "specs/<capability>/spec.md."},
    {{:spec, :invalid_issues, [%{index: 1, message: "severity must be P1, P2 or P3"}]},
     "Invalid issues: issue 1: severity must be P1, P2 or P3."},
    {{:spec, :invalid_archive, "the archive has no spec file"},
     "Invalid archive: the archive has no spec file. Upload a tar.gz or zip of an OpenSpec " <>
       "change directory (at most 2 MB, 200 entries and 1 MB of files; regular files only)."}
  ]

  test "the English text of each spec error", ctx do
    error_ctx = %Context{
      tool: "submit_spec_version",
      args: %{"task_id" => "BOS-12", "base_version" => 2, "version" => 3},
      scope: ctx.alice_scope,
      session: nil
    }

    for {reason, text} <- @texts do
      assert ErrorText.format(reason, error_ctx) == {:ok, text}
    end
  end
end
