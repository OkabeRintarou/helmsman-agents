defmodule HelmsmanWeb.AgentDesignE2ETest do
  @moduledoc """
  add-agent-conversation-ui tasks 5.2: the page from the first message to the created
  agent. The daemon side is driven as the daemon does (`Helmsman.RunLifecycleFixtures`),
  the draft tool is called over `/mcp` with the run token of the run description, and
  the turn is settled by its job (the facility of add-agent-conversation 5.1).
  """
  # The anubis session processes are not children of the test process.
  use HelmsmanWeb.ConnCase, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunLifecycleFixtures

  alias Helmsman.{AgentDesigns, Agents, Runs}
  alias Helmsman.AgentDesigns.SettleTurn
  alias HelmsmanWeb.MCPClient

  test "start, the helper drafts over /mcp and replies, confirm, the agent page", %{conn: conn} do
    ctx = design_fixture()
    slug = ctx.workspace.slug
    conn = log_in_user(conn, ctx.alice)
    {:ok, view, _html} = live(conn, "/w/#{slug}/agent-design")

    view
    |> form("#design-start-form", %{"message" => "我需要一个用 Tailwind 的前端开发", "helper" => "helper"})
    |> render_submit()

    assert has_element?(view, "#design-turn-phase", "排队中")

    {:ok, [spec]} = Runs.claim(dctx(ctx.helper), "http://localhost:4000")
    assert spec.prompt =~ "我需要一个用 Tailwind 的前端开发"
    start!(ctx.helper, spec.run_id)
    append!(ctx.helper, spec.run_id, [event(1, :text, %{text: "我先起草一个前端 Agent"})])
    assert has_element?(view, "#design-turn-phase", "正在回复")
    assert has_element?(view, "#design-turn-items [data-item=text]", "我先起草一个前端 Agent")

    token = spec.mcp.token
    sid = MCPClient.handshake(token)

    assert {:ok, %{"agent" => %{"name" => "fe-dev"}}} =
             MCPClient.call_tool(token, sid, "propose_agent", %{
               name: "fe-dev",
               provider: "claude",
               runtime_id: ctx.runtime.id,
               model: "sonnet",
               effort: "high",
               instructions: "用 Tailwind 写界面。"
             })

    assert has_element?(view, "#draft-agent-0[data-name=fe-dev] [data-updated-by=ai]")
    assert has_element?(view, "#draft-agent-0 [data-field=runtime_id]", "alice-mbp · 在线")

    finish!(ctx.helper, spec.run_id, :succeeded, %{summary: "我起草了 **fe-dev**，还要别的吗？"})
    assert :ok = perform_job(SettleTurn, %{run_id: spec.run_id})

    refute has_element?(view, "#design-turn")
    assert has_element?(view, "#design-messages [data-role=assistant] strong", "fe-dev")

    view |> element("#design-confirm-open") |> render_click()
    assert open?(view, "design-confirm")
    render_click(view, "dismiss_confirm", %{})

    {:ok, %{draft_version: version}} = AgentDesigns.current(ctx.alice_scope)
    result = render_click(view, "confirm", %{"version" => to_string(version)})
    assert {:error, {:live_redirect, %{to: to}}} = result
    assert to == "/w/#{slug}/agents/fe-dev"

    {:ok, _show, html} = follow_redirect(result, conn)
    assert html =~ "已创建 fe-dev"
    assert {:ok, agent} = Agents.get(ctx.alice_scope, "fe-dev")
    assert agent.owner.id == ctx.alice.id
    assert %{model: "sonnet", effort: "high"} = agent
  end
end
