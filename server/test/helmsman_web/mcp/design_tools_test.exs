defmodule HelmsmanWeb.MCP.DesignToolsTest do
  # add-edit-design-conversations 1.2: the draft tools by conversation kind
  # (agent-design 「对话的种类与槽位」 tool table, MODIFIED 「草稿工具」;
  # decision 7). Shared sandbox (anubis sessions).
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Runs
  alias Helmsman.Runs.RunTokens
  alias HelmsmanMCP.Pipeline
  alias HelmsmanWeb.MCPClient

  @draft_tools ~w(get_design propose_agent withdraw_agent propose_squad)

  defp token(ctx) do
    {:ok, [spec]} = Runs.claim(dctx(ctx.helper), "http://localhost:4000")
    start!(ctx.helper, spec.run_id)
    spec.mcp.token
  end

  defp listed(token) do
    sid = MCPClient.handshake(token)
    resp = MCPClient.rpc(token, sid, "tools/list")

    Jason.decode!(resp.body)["result"]["tools"]
    |> Enum.map(& &1["name"])
    |> Enum.filter(&(&1 in @draft_tools))
    |> Enum.sort()
  end

  defp call(token, tool, args) do
    {:ok, scope} = RunTokens.scope(token)
    Pipeline.call_tool(tool, args, scope, nil)
  end

  defp open(kind) do
    ctx = design_fixture()
    Helmsman.AgentsFixtures.managed_agent_fixture(ctx.alice_scope, %{name: "fe-dev"})
    target = agent_actor(ctx.workspace, "fe-dev")

    case kind do
      :agent -> start_design!(ctx.alice_scope)
      :squad -> start_squad_design!(ctx)
      edit -> {:ok, _} = start_kind(ctx.alice_scope, edit, target)
    end

    token(ctx)
  end

  test "tools/list by kind" do
    assert listed(open(:agent)) == ~w(get_design propose_agent withdraw_agent)
    assert listed(open(:squad)) == ~w(get_design propose_agent propose_squad withdraw_agent)
    assert listed(open(:agent_edit)) == ~w(get_design propose_agent)
    assert listed(open(:squad_edit)) == ~w(get_design propose_agent propose_squad withdraw_agent)
  end

  test "a tool outside the kind is refused with the kind; the draft is unchanged" do
    token = open(:agent_edit)

    assert call(token, "withdraw_agent", %{"name" => "fe-dev"}) ==
             {:error,
              "This is an agent edit conversation: withdraw_agent is not available. " <>
                "The draft was not changed."}

    assert call(token, "propose_squad", %{"name" => "x"}) ==
             {:error,
              "This is an agent edit conversation: propose_squad is not available. " <>
                "The draft was not changed."}

    assert call(open(:agent), "propose_squad", %{"name" => "x"}) ==
             {:error, "This is not a squad conversation: propose_squad is not available."}
  end

  test "an ordinary run sees no draft tool and is refused" do
    ctx = design_fixture()
    run = run_fixture(ctx.helper, %{status: :running, daemon_id: ctx.daemon.id})
    {_scope, token} = run_scope_fixture(run)
    assert listed(token) == []
    assert {:error, _text} = call(token, "propose_agent", %{"name" => "x"})
  end
end
