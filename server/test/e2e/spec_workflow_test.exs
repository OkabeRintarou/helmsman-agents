defmodule Helmsman.E2E.SpecWorkflowTest do
  # add-spec-workflow 5.1: the real daemon drives fake CLIs which call /mcp
  # over HTTP with the actual run token, including delegation and wake-ups.
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 240_000
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.TaskSpecsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{Actors, CommittedData, DaemonE2E, Repo, Tasks, TaskSpecs}
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs.Run
  alias Helmsman.TaskSpecs.{Event, Issue, IssueNote, Review, ReviewRequest, Spec, State, Version}

  @cli_script Path.expand("../support/fake_cli/spec-workflow-mcp.py", __DIR__)

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-e2e-spec-#{tag}")
    File.mkdir_p!(home)
    unless System.get_env("HELMSMAN_E2E_KEEP"), do: on_exit(fn -> File.rm_rf!(home) end)

    {alice, workspace, scope, project, daemon, token, api_token} =
      CommittedData.unboxed(fn ->
        alice = user_fixture(%{email: "spec-e2e-#{tag}@test.invalid"})
        workspace = workspace_fixture(alice, %{slug: "spec-e2e-#{tag}"})
        scope = workspace_scope_fixture(alice, workspace)
        {:ok, actor} = Actors.rename_own(scope, "alice")
        scope = %{scope | actor: actor}
        project = project_fixture(scope, %{key: "BOS", spec_finalize: :approval})
        {daemon, token} = daemon_fixture(alice, %{workspace_ids: [workspace.id]})
        %{token: api_token} = api_token_fixture(scope)
        {alice, workspace, scope, project, daemon, token, api_token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([alice.id]) end)

    %{
      home: home,
      scope: scope,
      project: project,
      workspace: workspace,
      daemon: daemon,
      token: token,
      api_token: api_token
    }
  end

  defp start(ctx) do
    url = DaemonE2E.start_endpoint()
    DaemonE2E.write_credentials(ctx.home, url, ctx.daemon.id, ctx.token)
    # A wake-up can arrive before the daemon releases the previous run's
    # capacity. Its regular heartbeat retries the claim; shorten it here.
    port = DaemonE2E.start_e2e_daemon(ctx.home, %{heartbeat_interval_ms: 100})

    runtime =
      DaemonE2E.wait_until(port, "runtime online", fn ->
        case Repo.get_by(Runtime, daemon_id: ctx.daemon.id, workspace_id: ctx.workspace.id) do
          %Runtime{status: "online"} = runtime -> runtime
          _ -> nil
        end
      end)

    {port, runtime, url}
  end

  # MCP writes select an agent identity. A person uses REST, which keeps
  # the token owner's human identity when no actor override is supplied.
  defp human_request(ctx, url, method, suffix, args) do
    response =
      Req.request!(
        method: method,
        url: "#{url}/api/v1/w/#{ctx.workspace.slug}/tasks/#{ctx.task.ident}/spec#{suffix}",
        headers: [{"authorization", "Bearer " <> ctx.api_token}],
        json: args,
        retry: false
      )

    assert response.status in [200, 201], inspect(response.body)
    response.body["data"]
  end

  defp call(tool, args, error \\ false),
    do: %{tool: tool, args: Map.put(args, :task_id, "BOS-1"), error: error}

  defp turn(name, calls), do: %{name: name, calls: calls}

  defp delegate(to, role),
    do: call("delegate", %{to: to, spec: role, instructions: "Spec #{role}"})

  defp submit(base, files),
    do:
      call("submit_spec_version", %{
        base_version: base,
        files:
          Enum.map(Enum.sort(files), fn {path, content} -> %{path: path, content: content} end)
      })

  defp install_cli(ctx, runtime, name, turns) do
    basename = name |> String.split("/") |> List.last()
    plan = Path.join(ctx.home, "#{basename}.json")
    scenario = Path.join(ctx.home, "#{basename}.scenario")
    File.write!(plan, Jason.encode!(turns))
    command = Enum.map_join(["python3", @cli_script, plan, ctx.home], " ", &shell_quote/1)
    File.write!(scenario, "sh #{command}\nexit 0\n")

    managed_agent_fixture(ctx.scope, %{
      name: name,
      runtime_id: runtime.id,
      access: "workspace",
      custom_args: [scenario]
    })
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp marker(ctx, name, suffix), do: Path.join(ctx.home, "#{name}.#{suffix}")

  defp receipt(port, ctx, name, suffix) do
    DaemonE2E.wait_until(port, "#{name}.#{suffix}", fn ->
      error = marker(ctx, name, "error")

      refute File.exists?(error),
             "fake CLI failed: #{if File.exists?(error), do: File.read!(error)}"

      case File.read(marker(ctx, name, suffix)) do
        {:ok, json} -> Jason.decode!(json)
        _ -> nil
      end
    end)
  end

  defp ready(port, ctx, name) do
    receipt = receipt(port, ctx, name, "ready")
    run = Repo.get!(Run, receipt["run_id"])
    assert run.status == :running
    {run, receipt["prompt"]}
  end

  defp execute(port, ctx, name) do
    File.write!(marker(ctx, name, "release"), "")
    receipt(port, ctx, name, "done")["results"]
  end

  defp finish(port, ctx, name, run) do
    File.write!(marker(ctx, name, "finish"), "")

    ended =
      DaemonE2E.wait_until(port, "#{name} ended", fn ->
        current = Repo.get!(Run, run.id)
        current.status in Run.ended_statuses() && current
      end)

    assert ended.status == :succeeded
    assert ended.summary == "#{name} completed."
    assert %{failure: 0} = Oban.drain_queue(queue: :runs)
  end

  defp checkpoint(ctx, status, latest, resolution \\ nil) do
    spec = Repo.get_by!(Spec, task_id: ctx.task.id)
    assert {spec.status, spec.latest_version} == {status, latest}
    events = Repo.all(from(e in Event, where: e.spec_id == ^spec.id, order_by: e.number))
    assert Enum.map(events, & &1.number) == Enum.to_list(1..length(events))

    notes =
      Repo.all(
        from(n in IssueNote,
          join: i in Issue,
          on: i.id == n.issue_id,
          join: r in Review,
          on: r.id == i.review_id,
          where: i.spec_id == ^spec.id,
          select: %{review: r.number, issue: i.number, number: n.number, resolution: n.resolution}
        )
      )

    replay = State.replay(Enum.map(events, &Map.from_struct/1), notes)

    assert replay.spec == %{
             status: spec.status,
             change_id: spec.change_id,
             latest_version: spec.latest_version,
             final_version: spec.final_version,
             proposal:
               if(spec.proposal_version,
                 do: %{
                   version: spec.proposal_version,
                   summary: spec.proposal_summary,
                   by_id: spec.proposal_by_id,
                   run_id: spec.proposal_run_id,
                   at: spec.proposed_at
                 }
               )
           }

    requests =
      Repo.all(
        from(r in ReviewRequest,
          join: v in Version,
          on: v.id == r.version_id,
          left_join: review in Review,
          on: review.id == r.review_id,
          where: r.spec_id == ^spec.id,
          select:
            {r.number,
             %{
               version: v.number,
               status: r.status,
               close_reason: r.close_reason,
               review: review.number
             }}
        )
      )
      |> Map.new()

    assert requests == replay.requests

    if resolution do
      issue = Repo.get_by!(Issue, spec_id: spec.id)
      assert issue.resolution == resolution
      assert Map.get(replay.issues, {1, 1}, :open) == resolution
    end

    spec
  end

  test "draft → review → disputed revision → ruling → v4 proposal → human approval", ctx do
    {port, runtime, url} = start(ctx)
    delta = "specs/settings/spec.md"

    install_cli(ctx, runtime, "keel/lead", [
      turn("lead-1", [delegate("keel/fe", "draft")]),
      turn("lead-2", [delegate("keel/review", "review")]),
      turn("lead-3", [
        call("finalize_spec", %{version: 2, summary: "Still blocked"}, true),
        delegate("keel/fe", "revise")
      ]),
      turn("lead-4", [
        call("finalize_spec", %{version: 3, summary: "Disputed"}, true),
        call("rule_spec_issue", %{
          issue: "R1.1",
          ruling: "upheld",
          reason: "The requirement needs the stronger guarantee."
        }),
        delegate("keel/fe", "revise")
      ]),
      turn("lead-5", [
        call("finalize_spec", %{
          version: 4,
          summary: "P1 ruled upheld; v4 implements the required guarantee."
        })
      ]),
      turn("lead-6", [])
    ])

    install_cli(ctx, runtime, "keel/fe", [
      turn("fe-1", [
        submit(0, spec_files(invalid: true)),
        submit(1, Map.take(spec_files(), [delta]))
      ]),
      turn("fe-2", [
        call("reply_spec_issue", %{
          issue: "R1.1",
          resolution: "disputed",
          body: "The existing guarantee should suffice."
        }),
        submit(2, Map.take(spec_files(tag: "disputed v3"), [delta]))
      ]),
      turn("fe-3", [submit(3, Map.take(spec_files(tag: "stronger guarantee v4"), [delta]))])
    ])

    install_cli(ctx, runtime, "keel/review", [
      turn("review-1", [
        call("get_spec", %{}),
        call("diff_spec", %{from: 1, to: 2}),
        call("submit_spec_review", %{
          version: 2,
          verdict: "fail",
          summary: "One blocking guarantee",
          issues: [
            %{
              severity: "P1",
              file: delta,
              line: 4,
              body: "Require a stronger guarantee",
              suggestion: "Describe it explicitly."
            }
          ]
        })
      ])
    ])

    squad =
      squad_fixture(ctx.scope, %{
        name: "web-team",
        leader: "keel/lead",
        spec_finalize: :approval,
        members: [
          %{name: "keel/fe", role_note: "Draft and revise"},
          %{name: "keel/review", role_note: "Review"}
        ]
      })

    task = task_fixture(ctx.scope, ctx.project.key, %{title: "Specify settings"})
    assert task.ident == "BOS-1"
    ctx = Map.put(ctx, :task, task)
    assert %{"latest_version" => 0} = human_request(ctx, url, :patch, "", %{})

    checkpoint(ctx, :draft, 0)
    assert {:ok, _} = Tasks.update(ctx.scope, task.ident, %{assignee: squad.name})

    {leader1, prompt} = ready(port, ctx, "lead-1")
    assert leader1.squad_id == squad.id
    assert prompt =~ "Spec: BOS-1 needs a spec"
    assert prompt =~ "a person must approve"
    assert [%{"value" => %{"run" => %{"agent" => "keel/fe"}}}] = execute(port, ctx, "lead-1")
    finish(port, ctx, "lead-1", leader1)
    {draft, prompt} = ready(port, ctx, "fe-1")
    assert [%{"kind" => "delegated", "spec_role" => "draft"}] = draft.triggers
    assert prompt =~ "Your job: draft the spec"

    assert [
             %{"value" => %{"version" => 1, "validation" => %{"valid" => false}}},
             %{"value" => %{"version" => 2, "validation" => %{"valid" => true}}}
           ] = execute(port, ctx, "fe-1")

    checkpoint(ctx, :draft, 2)
    finish(port, ctx, "fe-1", draft)

    {leader2, prompt} = ready(port, ctx, "lead-2")
    assert [%{"kind" => "delegate_done", "member" => "keel/fe"}] = leader2.triggers
    assert prompt =~ "fe-1 completed."
    execute(port, ctx, "lead-2")
    spec = checkpoint(ctx, :in_review, 2)
    request = Repo.get_by!(ReviewRequest, spec_id: spec.id)
    assert request.request_run_id == leader2.id
    assert request.status == :requested
    finish(port, ctx, "lead-2", leader2)
    {review, prompt} = ready(port, ctx, "review-1")

    assert [%{"spec_role" => "review", "spec_version" => 2, "spec_request" => 1}] =
             review.triggers

    assert prompt =~ "submit_spec_review"
    results = execute(port, ctx, "review-1")

    assert [
             %{"value" => %{"version" => %{"number" => 2, "validation" => %{"valid" => true}}}},
             %{"value" => %{"from" => 1, "to" => 2, "files" => diff_files}},
             %{"value" => %{"review" => 1, "issues" => ["R1.1"]}}
           ] = results

    assert Enum.any?(diff_files, &(&1["path"] == delta and &1["change"] == "modified"))
    checkpoint(ctx, :draft, 2, :open)
    finish(port, ctx, "review-1", review)

    {leader3, prompt} = ready(port, ctx, "lead-3")
    assert [%{"kind" => "delegate_done", "member" => "keel/review"}] = leader3.triggers
    assert prompt =~ "review-1 completed."
    [%{"error" => true, "value" => blocked}, _] = execute(port, ctx, "lead-3")
    assert blocked =~ "R1.1"
    finish(port, ctx, "lead-3", leader3)
    {revise1, prompt} = ready(port, ctx, "fe-2")
    assert prompt =~ "Your job: revise the spec after review"
    assert [%{"spec_role" => "revise"}] = revise1.triggers
    execute(port, ctx, "fe-2")
    checkpoint(ctx, :draft, 3, :disputed)
    finish(port, ctx, "fe-2", revise1)

    {leader4, _} = ready(port, ctx, "lead-4")

    [%{"error" => true, "value" => blocked}, %{"value" => %{"resolution" => "upheld"}}, _] =
      execute(port, ctx, "lead-4")

    assert blocked =~ "R1.1"
    checkpoint(ctx, :draft, 3, :upheld)
    finish(port, ctx, "lead-4", leader4)
    {revise2, _} = ready(port, ctx, "fe-3")
    assert [%{"value" => %{"version" => 4}}] = execute(port, ctx, "fe-3")
    checkpoint(ctx, :draft, 4, :upheld)
    finish(port, ctx, "fe-3", revise2)

    {leader5, _} = ready(port, ctx, "lead-5")

    assert [%{"value" => %{"status" => "pending_approval", "decision" => "proposed"}}] =
             execute(port, ctx, "lead-5")

    checkpoint(ctx, :pending_approval, 4, :upheld)

    assert {:ok, %{latest_version: 4, status: :pending_approval}} =
             TaskSpecs.summary(ctx.scope, task.ident)

    finish(port, ctx, "lead-5", leader5)

    versions_before =
      Repo.all(from(v in Version, where: v.spec_id == ^spec.id, order_by: v.number))

    assert %{"decision" => "approved", "dispatch" => %{"result" => "queued"}} =
             human_request(ctx, url, :post, "/finalize", %{
               version: 4,
               summary: "Approved v4 after reviewing the ruling and revision.",
               wake: true
             })

    final = checkpoint(ctx, :finalized, 4, :upheld)
    assert final.final_version == 4
    assert final.proposal_version == nil

    assert Repo.all(from(v in Version, where: v.spec_id == ^spec.id, order_by: v.number)) ==
             versions_before

    {leader6, prompt} = ready(port, ctx, "lead-6")
    assert leader6.squad_id == squad.id

    assert [%{"kind" => "spec_decided", "decision" => "approved", "version" => 4}] =
             leader6.triggers

    assert prompt =~ "The spec of BOS-1 is final (version 4)."
    assert prompt =~ "alice approved the spec of BOS-1"
    execute(port, ctx, "lead-6")
    finish(port, ctx, "lead-6", leader6)
    assert_history(ctx, spec, draft, review, revise1, revise2, leader4, leader5)
    DaemonE2E.stop_daemon(port)
  end

  defp assert_history(ctx, spec, draft, review, revise1, revise2, leader4, leader5) do
    events = Repo.all(from(e in Event, where: e.spec_id == ^spec.id, order_by: e.number))

    assert Enum.map(events, &{&1.action, &1.version}) == [
             {"created", nil},
             {"version_submitted", 1},
             {"version_submitted", 2},
             {"review_requested", 2},
             {"review_submitted", 2},
             {"version_submitted", 3},
             {"version_submitted", 4},
             {"finalize_proposed", 4},
             {"approved", 4}
           ]

    versions = Repo.all(from(v in Version, where: v.spec_id == ^spec.id, order_by: v.number))

    assert Enum.map(versions, &{&1.number, &1.valid, &1.source_run_id}) == [
             {1, false, draft.id},
             {2, true, draft.id},
             {3, true, revise1.id},
             {4, true, revise2.id}
           ]

    assert Repo.get_by!(Review, spec_id: spec.id).source_run_id == review.id

    notes =
      Repo.all(
        from(n in IssueNote,
          join: i in Issue,
          on: i.id == n.issue_id,
          where: i.spec_id == ^spec.id,
          order_by: n.number
        )
      )

    assert Enum.map(notes, &{&1.kind, &1.resolution, &1.source_run_id}) == [
             {:reply, :disputed, revise1.id},
             {:ruling, :upheld, leader4.id}
           ]

    assert Enum.find(events, &(&1.action == "finalize_proposed")).source_run_id == leader5.id
    assert List.last(events).actor_id == ctx.scope.actor.id
    assert List.last(events).source_run_id == nil
    assert Repo.get!(Tasks.Task, ctx.task.id).status == :in_progress
    assert length(runs_of(ctx.task.id)) == 10
  end
end
