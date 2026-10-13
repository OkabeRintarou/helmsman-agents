defmodule HelmsmanWeb.AgentDesignTurnTest do
  @moduledoc """
  Spec web-agent-design 当前轮 (add-agent-conversation-ui D5): the phase, the live text of
  the turn's run (text and folded tool calls only), 停止, the end of a turn and the
  subscription following the current run.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.AgentDesignHelpers
  import Helmsman.RunsFixtures, only: [agent_actor: 2, daemon_of: 1]
  import Helmsman.RunLifecycleFixtures, only: [append!: 3, event: 3, set_run!: 2]

  alias Helmsman.AgentDesigns
  alias HelmsmanWeb.AgentDesignTurn

  setup :design_setup

  # The turn's run starts running on the helper's daemon.
  defp running!(ctx, run_id) do
    actor = agent_actor(ctx.ws, "helper")
    now = DateTime.utc_now()

    set_run!(run_id,
      status: :running,
      daemon_id: daemon_of(actor).id,
      claimed_at: now,
      started_at: now
    )

    actor
  end

  defp tool(seq, name, input),
    do: event(seq, :tool_call, %{call_id: "c#{seq}", name: name, input: input})

  defp subscribed?(view, run_id),
    do:
      Enum.any?(Registry.lookup(Helmsman.PubSub, "run:#{run_id}"), fn {pid, _} ->
        pid == view.pid
      end)

  test "实时文本: text and a folded tool call, nothing else", ctx do
    design = start!(ctx)
    run_id = design.current_run.id
    actor = running!(ctx, run_id)
    {view, _} = open_page(ctx)

    append!(actor, run_id, [
      event(1, :text, %{text: "我先看看工作区里已有的 Agent"}),
      tool(
        2,
        "mcp__helmsman__propose_agent",
        ~s({"name":"fe-dev","instructions":"SECRET-INPUT"})
      ),
      event(3, :tool_result, %{
        call_id: "c2",
        output: "TOOL-OUTPUT",
        is_error: false,
        truncated: false
      }),
      event(4, :thinking, %{text: "THINKING-TEXT"}),
      event(5, :text, %{text: "我建议用 sonnet"})
    ])

    items =
      view
      |> element("#design-turn-items")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-item]")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))

    assert items == ["我先看看工作区里已有的 Agent", "更新了草稿：fe-dev", "我建议用 sonnet"]
    html = render(view)
    for hidden <- ~w(SECRET-INPUT TOOL-OUTPUT THINKING-TEXT), do: refute(html =~ hidden)
  end

  test "opening the page mid-turn reads the turn's latest events", ctx do
    design = start!(ctx)
    run_id = design.current_run.id
    actor = running!(ctx, run_id)
    append!(actor, run_id, [event(1, :text, %{text: "已经说过的话"})])
    {view, _} = open_page(ctx)

    assert has_element?(view, "#design-turn-phase", "正在回复")
    assert has_element?(view, "#design-turn-items [data-item=text]", "已经说过的话")
    assert has_element?(view, ~s(#design-turn-run[href="/w/#{ctx.ws.slug}/runs/#{run_id}"]))
  end

  test "排队说明", ctx do
    start!(ctx)
    {view, _} = open_page(ctx)
    assert has_element?(view, "#design-turn-phase", "排队中")
    assert has_element?(view, "#design-turn-queue", "最多等 10 分钟")
  end

  test "停止当前轮", ctx do
    start!(ctx)
    {view, _} = open_page(ctx)
    view |> element("#design-turn-stop") |> render_click()

    refute has_element?(view, "#design-turn")
    assert has_element?(view, "[data-code=stopped]", "已停止这一轮")
    refute has_element?(view, "#design-send-form textarea[disabled]")
  end

  test "一轮结束", ctx do
    design = start!(ctx)
    {view, _} = open_page(ctx)
    reply!(design.id, "你希望它负责 Storybook 吗？")

    refute has_element?(view, "#design-turn")
    assert has_element?(view, "#design-messages [data-role=assistant]", "你希望它负责 Storybook 吗？")
    refute has_element?(view, "#design-send-form textarea[disabled]")
  end

  test "换轮时退订旧运行主题", ctx do
    design = start!(ctx)
    first = design.current_run.id
    {view, _} = open_page(ctx)
    assert subscribed?(view, first)

    reply!(design.id, "好")
    {:ok, next} = AgentDesigns.send(ctx.alice_scope, design.id, "继续")
    second = next.current_run.id
    render(view)

    refute subscribed?(view, first)
    assert subscribed?(view, second)

    send(
      view.pid,
      {:run_events, first, [%{seq: 9, type: "text", data: %{"text" => "旧运行的文字"}, at: nil}]}
    )

    refute render(view) =~ "旧运行的文字"
    end_turn!(design.id, :cancelled)
    render(view)
    refute subscribed?(view, second)
  end

  # code-review-1 P2-2: past the joined-text limit the latest output still shows.
  test "long text: later output stays visible, in order with tool calls", ctx do
    design = start!(ctx)
    run_id = design.current_run.id
    actor = running!(ctx, run_id)
    {view, _} = open_page(ctx)

    long = String.duplicate("a", 20_000)
    append!(actor, run_id, [event(1, :text, %{text: long})])
    append!(actor, run_id, [event(2, :text, %{text: "LATEST-1"})])
    append!(actor, run_id, [tool(3, "propose_agent", ~s({"name":"fe-dev"}))])

    append!(actor, run_id, [event(4, :text, %{text: "LATEST-2"})])

    send(
      view.pid,
      {:run_events, run_id, [%{seq: 4, type: "text", data: %{"text" => "DUP"}, at: nil}]}
    )

    items =
      view
      |> element("#design-turn-items")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-item]")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))

    assert [first, "LATEST-1", "更新了草稿：fe-dev", "LATEST-2"] = items
    assert String.length(first) == 20_000
    refute render(view) =~ "DUP"
  end

  describe "tool_text/1" do
    test "by tool, with or without the MCP prefix" do
      assert AgentDesignTurn.tool_text(%{"name" => "propose_agent", "input" => ~s({"name":"qa"})}) ==
               "更新了草稿：qa"

      assert AgentDesignTurn.tool_text(%{
               "name" => "mcp__helmsman__withdraw_agent",
               "input" => ~s({"name":"qa"})
             }) ==
               "从草稿移除了 qa"

      assert AgentDesignTurn.tool_text(%{"name" => "mcp__helmsman__get_design", "input" => "{}"}) ==
               "读取了草稿"

      assert AgentDesignTurn.tool_text(%{"name" => "Bash", "input" => ~s({"command":"ls"})}) ==
               "调用了 Bash"
    end

    test "an input that is not JSON, or has no name, drops the name" do
      assert AgentDesignTurn.tool_text(%{
               "name" => "mcp__helmsman__propose_agent",
               "input" => "not json"
             }) ==
               "更新了草稿"

      assert AgentDesignTurn.tool_text(%{"name" => "propose_agent", "input" => ~s({"model":"x"})}) ==
               "更新了草稿"
    end
  end
end
