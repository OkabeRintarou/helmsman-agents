defmodule Helmsman.AgentDesigns.EndToEndTest do
  # add-agent-conversation 5.1: a conversation from the first message to
  # the created agent, with the daemon side driven as the daemon does
  # (Helmsman.RunLifecycleFixtures) and the draft tool called over /mcp
  # with the run token of the description. The anubis session processes
  # are not children of the test process: the sandbox runs in shared mode.
  use HelmsmanWeb.ConnCase, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunLifecycleFixtures

  alias Helmsman.{AgentDesigns, Agents, Events, Runs}
  alias Helmsman.AgentDesigns.SettleTurn
  alias HelmsmanWeb.MCPClient

  test "start, claim, propose over /mcp, reply, settle, confirm" do
    ctx = design_fixture()

    %{id: id} = start_design!(ctx.alice_scope, "I need a frontend developer using Tailwind")
    Events.subscribe(AgentDesigns.topic(id))

    # The daemon claims the turn: no task, the conversation in the prompt.
    {:ok, [spec]} = Runs.claim(dctx(ctx.helper), "http://localhost:4000")
    assert spec.task == nil and spec.repo == nil and spec.resume_session_id == nil
    assert spec.prompt =~ "> I need a frontend developer using Tailwind"
    start!(ctx.helper, spec.run_id)

    # The CLI writes the draft with the run token.
    token = spec.mcp.token
    sid = MCPClient.handshake(token)

    assert {:ok, %{"agent" => %{"name" => "fe-dev"}, "draft_version" => 1}} =
             MCPClient.call_tool(token, sid, "propose_agent", %{
               name: "fe-dev",
               provider: "claude",
               runtime_id: ctx.runtime.id,
               model: "sonnet",
               effort: "high",
               instructions: "You build the web UI with Tailwind."
             })

    assert_receive {:agent_design, ^id}

    # Its last output is the reply.
    finish!(ctx.helper, spec.run_id, :succeeded, %{summary: "I drafted fe-dev. Anything else?"})
    assert_enqueued(worker: SettleTurn, args: %{run_id: spec.run_id})
    assert :ok = perform_job(SettleTurn, %{run_id: spec.run_id})

    {:ok, view} = AgentDesigns.get(ctx.alice_scope, id)
    assert view.current_run == nil

    assert %{role: :assistant, content: "I drafted fe-dev. Anything else?"} =
             List.last(view.messages)

    # The token died with the run.
    assert MCPClient.rpc(token, sid, "tools/list").status == 401

    assert {:ok, %{agents: [%{name: "fe-dev"}]}} =
             AgentDesigns.confirm(ctx.alice_scope, id, view.draft_version)

    assert {:ok, agent} = Agents.get(ctx.alice_scope, "fe-dev")
    assert agent.owner.id == ctx.alice.id
    assert %{model: "sonnet", effort: "high", kind: "managed"} = agent
  end
end
