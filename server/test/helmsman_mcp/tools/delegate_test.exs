defmodule HelmsmanMCP.Tools.DelegateTest do
  # add-squads 4.1: `delegate` with a run token through the MCP pipeline:
  # the result and the English text of every error (decision 8).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Runs, Squads, Tasks}
  alias Helmsman.Runs.{Run, RunTokens}
  alias HelmsmanMCP.Pipeline

  setup do
    ctx = squads_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "web-team"})
    {:ok, [spec]} = Runs.claim(dctx(ctx.lead), "http://localhost:4000")
    start!(ctx.lead, spec.run_id)
    Map.merge(ctx, %{task: task, token: spec.mcp.token, run_id: spec.run_id})
  end

  defp call(ctx, args) do
    {:ok, scope} = RunTokens.scope(ctx.token)

    case Pipeline.call_tool("delegate", Map.put_new(args, "task_id", ctx.task.ident), scope, nil) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      error -> error
    end
  end

  test "delegated: the member's run", ctx do
    assert {:ok, %{"merged" => false, "run" => %{"agent" => "keel/fe", "status" => "QUEUED"}}} =
             call(ctx, %{"to" => "keel/fe", "instructions" => "Implement it"})
  end

  test "the error texts", ctx do
    ident = ctx.task.ident
    bob = human_actor(ctx.workspace, ctx.bob).name
    managed_agent_fixture(ctx.carol_scope, %{name: "carol/dev"})

    assert call(ctx, %{"to" => "carol/dev", "instructions" => "x"}) ==
             {:error,
              "carol/dev is not a member agent of the squad web-team. You can delegate to: " <>
                "keel/fe, keel/review, keel/qa."}

    assert call(ctx, %{"to" => bob, "instructions" => "x"}) ==
             {:error,
              "#{bob} is a person in the squad and cannot be delegated a run. When you need " <>
                "their decision, write a question on the task with add_feedback (kind \"question\")."}

    assert call(ctx, %{"to" => "keel/fe", "instructions" => " "}) ==
             {:error, "Give the member instructions: what to do in its run."}

    assert call(ctx, %{"to" => "keel/fe", "instructions" => String.duplicate("x", 8193)}) ==
             {:error, "instructions are too long (max 8 KB). Put details in the task instead."}

    # The source may not trigger the owner_only member.
    Repo.update_all(from(r in Run, where: r.id == ^ctx.run_id),
      set: [root_initiator_user_id: ctx.bob.id]
    )

    assert call(ctx, %{"to" => "keel/qa", "instructions" => "Test it"}) ==
             {:error,
              "cannot_invoke: #{bob} may not trigger keel/qa. Pick another member, or say so " <>
                "in a question on the task."}

    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/lead2",
      runtime_id: ctx.runtime_id,
      access: "workspace"
    })

    {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/lead2"})

    assert call(ctx, %{"to" => "keel/fe", "instructions" => "x"}) ==
             {:error, "You no longer lead the squad web-team: you cannot delegate. End this run."}

    {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")

    assert call(ctx, %{"to" => "keel/fe", "instructions" => "x"}) ==
             {:error, "The squad web-team is disabled: nothing can be delegated. End this run."}

    Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id),
      set: [assignee_id: ctx.agent.id]
    )

    assert call(ctx, %{"to" => "keel/fe", "instructions" => "x"}) ==
             {:error,
              "#{ident} is no longer assigned to your squad web-team; you can only delegate " <>
                "your squad's task. End this run."}

    Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id), set: [status: :done])

    assert call(ctx, %{"to" => "keel/fe", "instructions" => "x"}) ==
             {:error, "#{ident} is not new or in progress: there is nothing to delegate."}
  end

  test "another agent's run: forbidden", ctx do
    run =
      run_fixture(ctx.fe, %{
        task_id: ctx.task.id,
        status: :running,
        capabilities: ["read", "write_task"]
      })

    {scope, _token} = run_scope_fixture(run)

    assert {:error, text} =
             Pipeline.call_tool(
               "delegate",
               %{"task_id" => ctx.task.ident, "to" => "keel/review", "instructions" => "x"},
               scope,
               nil
             )

    assert text ==
             "This run can only read the workspace and change #{ctx.task.ident} " <>
               "(capabilities: read, write_task). Ask a human to do anything else."
  end
end

defmodule HelmsmanMCP.Tools.DelegateListTest do
  # add-squads 4.1: tools/list shows `delegate` only to a run with the
  # capability (decision 8). The anubis session processes are not
  # children of the test process: the sandbox runs in shared mode.
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Runs, Tasks}
  alias HelmsmanWeb.MCPClient

  defp tool_names(token, sid) do
    resp = MCPClient.rpc(token, sid, "tools/list")
    200 = resp.status
    Jason.decode!(resp.body)["result"]["tools"] |> Enum.map(& &1["name"])
  end

  test "a leader run lists delegate; a member's run does not", _ctx do
    ctx = squads_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "web-team"})
    {:ok, [spec]} = Runs.claim(dctx(ctx.lead), "http://localhost:4000")
    start!(ctx.lead, spec.run_id)

    sid = MCPClient.handshake(spec.mcp.token)
    assert "delegate" in tool_names(spec.mcp.token, sid)

    member =
      run_fixture(ctx.fe, %{
        task_id: task.id,
        status: :running,
        capabilities: ["read", "write_task"]
      })

    {_scope, token} = run_scope_fixture(member)
    sid = MCPClient.handshake(token)
    names = tool_names(token, sid)
    refute "delegate" in names
    assert "transition_task" in names
  end
end
