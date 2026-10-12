defmodule HelmsmanWeb.MCP.RunAgentTest do
  # The anubis session processes and their tool tasks are not children of
  # the test process: the sandbox runs in shared mode.
  use HelmsmanWeb.ConnCase, async: false

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias HelmsmanMCP.Sessions
  alias HelmsmanWeb.MCPClient

  setup do
    ctx = dispatch_fixture()
    bob = user_fixture()
    member_fixture(ctx.workspace, bob, :member)

    %{token: bob_token} =
      api_token_fixture(workspace_scope_fixture(bob, ctx.workspace), %{scopes: ["mcp"]})

    task = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.merge(ctx, %{bob: bob, bob_token: bob_token, task: task})
  end

  defp session_agents(user) do
    Repo.all(from(a in Actor, where: a.owner_id == ^user.id and like(a.name, "%/session-%")))
  end

  test "not dispatched: the write commits, the session agent is created and registered",
       ctx do
    sid = MCPClient.handshake(ctx.bob_token)

    assert {:error, text} =
             MCPClient.call_tool(ctx.bob_token, sid, "run_agent", %{
               agent: "keel/dev",
               task_id: ctx.task.ident
             })

    assert text =~ "keel/dev was not started: you are unauthorized to trigger it"
    assert runs_of(ctx.task.id) == []

    assert [%Actor{id: id}] = session_agents(ctx.bob)
    assert %{actor_id: ^id, source: :auto} = Sessions.lookup(sid)
  end

  test "a real failure rolls back: no session agent, no notification", ctx do
    Events.subscribe(Events.topic(:workspace_runs, ctx.workspace.id))
    sid = MCPClient.handshake(ctx.bob_token)

    assert {:error, text} =
             MCPClient.call_tool(ctx.bob_token, sid, "run_agent", %{
               agent: "keel/dev",
               task_id: "#{ctx.project.key}-999"
             })

    assert text =~ "not found"
    assert session_agents(ctx.bob) == []
    assert %{actor_id: nil} = Sessions.lookup(sid)
    refute_receive {:run_updated, _}
  end

  test "started: the run and whether it merged", ctx do
    %{token: token} =
      api_token_fixture(workspace_scope_fixture(ctx.alice, ctx.workspace), %{scopes: ["mcp"]})

    sid = MCPClient.handshake(token)
    args = %{agent: "keel/dev", task_id: ctx.task.ident, instructions: "add tests"}

    assert {:ok, %{"merged" => false, "run" => %{"id" => id, "status" => "QUEUED"} = run}} =
             MCPClient.call_tool(token, sid, "run_agent", args)

    assert [%{"kind" => "manual", "instructions" => "add tests"}] = run["triggers"]

    assert {:ok, %{"merged" => true, "run" => %{"id" => ^id}}} =
             MCPClient.call_tool(token, sid, "run_agent", args)

    assert {:ok, %{"runs" => [%{"id" => ^id}]}} =
             MCPClient.call_tool(token, sid, "list_runs", %{task_id: ctx.task.ident})
  end

  test "A → B → A through update_task with a run token: saved, dispatch says loop_detected",
       ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/review"})
    review = agent_actor(ctx.workspace, "keel/review")

    run =
      run_fixture(review, %{
        task_id: ctx.task.id,
        status: :running,
        causal_agent_ids: [ctx.agent.id, review.id],
        capabilities: ["read", "write_task"]
      })

    {_scope, token} = run_scope_fixture(run)
    sid = MCPClient.handshake(token)
    Events.subscribe(Events.topic(:task, ctx.task.id))

    assert {:ok, result} =
             MCPClient.call_tool(token, sid, "update_task", %{
               task_id: ctx.task.ident,
               assignee: "keel/dev"
             })

    assert result["assignee"]["name"] == "keel/dev"

    assert result["dispatch"] == [
             %{"agent" => "keel/dev", "result" => "skipped", "reason" => "loop_detected"}
           ]

    assert [%{"author" => %{"name" => "helmsman"}}] = result["feedback"]
    assert_receive {:feedback_added, _}
    refute_receive {:feedback_added, _}
    assert [%Run{id: id}] = runs_of(ctx.task.id)
    assert id == run.id
  end
end
