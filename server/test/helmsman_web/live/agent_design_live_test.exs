defmodule HelmsmanWeb.AgentDesignLiveTest do
  @moduledoc """
  Spec web-agent-design (add-agent-conversation-ui D1–D4, D8–D10, D15): entering the
  page, the start area, messages, sending, changing the helper, confirming and
  discarding, closing notes, live sync between tabs, the layout and secrets.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.AgentDesignHelpers
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures

  import Ecto.Query
  import Helmsman.RunsFixtures, only: [agent_actor: 2, profile: 1]

  alias Helmsman.{AgentDesigns, Agents, Repo}
  alias Helmsman.Daemons.Runtime
  alias HelmsmanWeb.AgentDesignComponents

  setup :design_setup

  defp send_message(view, text),
    do: view |> form("#design-send-form", %{"message" => text}) |> render_submit()

  describe "对话创建页的进入与权限" do
    test "没有进行中的对话: the start area", ctx do
      {view, html} = open_page(ctx)
      assert html =~ "用对话创建 Agent"
      assert page_title(view) =~ "用对话创建 Agent"
      assert has_element?(view, "#design-start textarea[name=message]")
      assert has_element?(view, "#design-start-helper")
      assert has_element?(view, "#design-visibility")
      assert has_element?(view, "#design-start-submit", "开始对话")
      refute has_element?(view, "#design")
    end

    test "已有进行中的对话: shown at once, no start area", ctx do
      start!(ctx, "我想要一个评审 Agent")
      {view, _html} = open_page(ctx)
      refute has_element?(view, "#design-start")
      assert has_element?(view, "#design-messages [data-role=user]", "我想要一个评审 Agent")
      assert has_element?(view, "#design-draft")
    end

    test "viewer", ctx do
      {view, html} = open_page(ctx, ctx.vic)
      assert html =~ "只有成员及以上角色能用对话创建 Agent"
      assert has_element?(view, "#design-forbidden")
      refute has_element?(view, "textarea")
    end

    test "owner 看不到别人的对话", ctx do
      bob_helper = managed_agent_fixture(ctx.bob_scope, %{name: "bob-helper"})

      {:ok, _} =
        AgentDesigns.start(ctx.bob_scope, %{helper: bob_helper.name, message: "BOB-SECRET-IDEA"})

      {view, html} = open_page(ctx, ctx.alice)
      assert has_element?(view, "#design-start")
      refute html =~ "BOB-SECRET-IDEA"
      refute render(view) =~ "BOB-SECRET-IDEA"
    end

    test "未登录: login, then back here", ctx do
      conn = get(build_conn(), ctx.path)
      assert redirected_to(conn) =~ "/users/log-in"
      assert get_session(conn, :user_return_to) == ctx.path
    end
  end

  describe "开始对话" do
    test "开始一个对话", ctx do
      {view, _html} = open_page(ctx)
      text = "帮我建一个前端开发 Agent，用 Tailwind，评审要严格"

      view
      |> form("#design-start-form", %{"message" => text, "helper" => "helper"})
      |> render_submit()

      refute has_element?(view, "#design-start")
      assert has_element?(view, "#design-messages [data-role=user]", text)
      assert has_element?(view, "#design-turn #design-turn-phase", "排队中")
      assert has_element?(view, "#design-draft-empty")
    end

    test "没有模板: an empty input, no templates or examples", ctx do
      {view, html} = open_page(ctx)

      [textarea] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#design-start textarea")
        |> Enum.to_list()

      assert LazyHTML.text(textarea) |> String.trim() == ""
      refute has_element?(view, "[data-template]")
      refute has_element?(view, "#design-start button[type=button]")

      assert view
             |> element("#design-start")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("button")
             |> Enum.count() == 1
    end

    test "别人的起草 Agent 的可见性说明", ctx do
      shared = managed_agent_fixture(ctx.bob_scope, %{name: "shared-helper", access: "workspace"})
      {view, _html} = open_page(ctx)

      view
      |> form("#design-start-form", %{"helper" => shared.name})
      |> render_change()

      note = view |> element("#design-visibility") |> render()
      assert note =~ "对话会在 bob 的机器上由 shared-helper 处理"
      assert note =~ "它的回复会出现在 shared-helper 的执行记录里，工作区成员都能看到"
      assert note =~ "不要粘贴密钥"
      assert note =~ "创建出的 Agent 属于你"
      assert has_element?(view, ~s(#design-start-helper option[value="shared-helper"]), "bob")
      assert has_element?(view, ~s(#design-start-helper option[value="helper"]), "你")
    end

    test "不能派发的起草 Agent", ctx do
      managed_agent_fixture(ctx.alice_scope, %{name: "old-helper"})
      {:ok, _} = Agents.disable(ctx.alice_scope, "old-helper")
      {view, _html} = open_page(ctx)

      assert has_element?(
               view,
               ~s(#design-start-helper option[value="old-helper"][disabled]),
               "已停用"
             )

      assert has_element?(view, ~s(#design-start-helper option[value="helper"][selected]))
    end

    test "没有可用的起草 Agent", ctx do
      {:ok, _} = Agents.disable(ctx.alice_scope, "helper")
      {view, _html} = open_page(ctx)
      assert has_element?(view, "#design-start-no-helper", "先新建一个 Agent")

      assert has_element?(
               view,
               ~s(#design-start-new-agent[href="/w/#{ctx.ws.slug}/agents?panel=new-agent"])
             )

      assert has_element?(view, "#design-start-submit[disabled]")
    end

    test "另一个标签页已经开始", ctx do
      {tab_a, _} = open_page(ctx)
      {tab_b, _} = open_page(ctx)

      tab_a
      |> form("#design-start-form", %{"message" => "第一个想法", "helper" => "helper"})
      |> render_submit()

      html =
        tab_b
        |> form("#design-start-form", %{"message" => "另一个想法", "helper" => "helper"})
        |> render_submit()

      assert html =~ "你已有一个进行中的对话，已为你打开"
      assert has_element?(tab_b, "#design-messages [data-role=user]", "第一个想法")
      refute has_element?(tab_b, "#design-messages", "另一个想法")
      assert tab_b |> element("#design-send-form textarea") |> render() =~ "另一个想法"
    end

    test "a message too long: the error under the input, input kept", ctx do
      {view, _} = open_page(ctx)
      long = String.duplicate("长", 3000)

      html =
        view
        |> render_submit("start", %{"message" => long, "helper" => "helper"})

      assert html =~ "data-message-error"
      assert has_element?(view, "#design-start")
      assert view |> element("#design-start textarea") |> render() =~ "长长长"
    end

    test "a helper disabled meanwhile: the reason under the select", ctx do
      {view, _} = open_page(ctx)
      {:ok, _} = Agents.disable(ctx.alice_scope, "helper")
      render_submit(view, "start", %{"message" => "你好", "helper" => "helper"})
      assert has_element?(view, "#design-start-helper-error", "已停用")
      assert view |> element("#design-start textarea") |> render() =~ "你好"
    end
  end

  describe "对话消息" do
    test "AI 回复按 Markdown 渲染并净化, with a link to its run", ctx do
      design = start!(ctx)
      run_id = design.current_run.id
      reply!(design.id, "建议用 **sonnet** <script>alert(1)</script>")
      {view, _} = open_page(ctx)

      assert has_element?(view, "#design-messages [data-role=assistant] strong", "sonnet")
      refute has_element?(view, "#design-messages script")

      assert has_element?(
               view,
               ~s([data-role=assistant] a[href="/w/#{ctx.ws.slug}/runs/#{run_id}"])
             )
    end

    test "失败的一轮", ctx do
      design = start!(ctx)
      run_id = design.current_run.id
      end_turn!(design.id, :failed, failure_reason: :provider_auth)
      {view, _} = open_page(ctx)

      assert has_element?(view, "[data-code=failed]", "这一轮失败：CLI 未登录")
      assert has_element?(view, ~s([data-code=failed] a[href="/w/#{ctx.ws.slug}/runs/#{run_id}"]))
    end

    test "every system message code has its text", ctx do
      design = start!(ctx)

      ends = [
        {"stopped", "已停止这一轮", fn -> AgentDesigns.stop_turn(ctx.alice_scope, design.id) end},
        {"queue_timeout", "helper 10 分钟内没有开始（可能正忙或离线），这一轮已取消",
         fn -> queue_timeout!(design.id) end},
        {"cancelled", "这一轮被取消", fn -> end_turn!(design.id, :cancelled) end},
        {"no_reply", "helper 没有回复文字", fn -> end_turn!(design.id, :succeeded) end}
      ]

      for {code, text, finish} <- ends do
        finish.()
        {view, _} = open_page(ctx)
        assert has_element?(view, "[data-code=#{code}]", text)
        {:ok, _} = AgentDesigns.send(ctx.alice_scope, design.id, "再来")
      end

      {:ok, _} = AgentDesigns.stop_turn(ctx.alice_scope, design.id)
      managed_agent_fixture(ctx.alice_scope, %{name: "codex-helper", provider: "codex"})
      {:ok, _} = AgentDesigns.change_helper(ctx.alice_scope, design.id, "codex-helper")
      {view, _} = open_page(ctx)
      assert has_element?(view, "[data-code=helper_changed]", "起草 Agent 换成了 codex-helper")
      assert AgentDesignComponents.system_text(%{code: "mystery"}, "helper") == "系统消息"
    end

    test "用户消息上的草稿修改", ctx do
      design = start!(ctx)
      propose!(design.id, %{"name" => "fe-dev", "model" => "sonnet"})
      propose!(design.id, %{"name" => "qa"})
      reply!(design.id, "好的")
      v = version(design.id)

      {:ok, _} =
        AgentDesigns.put_agent(ctx.alice_scope, design.id, v, %{
          "name" => "fe-dev",
          "model" => "opus"
        })

      {:ok, _} = AgentDesigns.remove_agent(ctx.alice_scope, design.id, v + 1, "qa")
      {view, _} = open_page(ctx)
      send_message(view, "再看看")

      edits =
        view |> element("#design-messages [data-role=user]:last-child [data-edits]") |> render()

      assert edits =~ "你修改了草稿：fe-dev（模型）"
      assert edits =~ "移除了 qa"
    end

    test "用量合计", ctx do
      design = start!(ctx)
      reply!(design.id, "一", %{"input_tokens" => 1000, "output_tokens" => 100})
      {:ok, _} = AgentDesigns.send(ctx.alice_scope, design.id, "二")

      reply!(design.id, "二", %{"input_tokens" => 2000, "output_tokens" => 200, "cost_usd" => 0.04})

      {view, _} = open_page(ctx)

      assert has_element?(view, "#design-usage", "输入 3.0k · 输出 300 · $0.04")
      assert has_element?(view, "#design-count", "2 / 40")
      assert has_element?(view, "#design-helper", "helper")
      assert has_element?(view, "#design-helper", "Claude Code")
      assert has_element?(view, "#design-helper", "你")
    end

    test "no usage line at zero", ctx do
      start!(ctx)
      {view, _} = open_page(ctx)
      refute has_element?(view, "#design-usage")
    end
  end

  describe "发送消息" do
    test "发送第二条消息", ctx do
      design = start!(ctx)
      reply!(design.id, "你希望用哪个模型？")
      {view, _} = open_page(ctx)

      assert has_element?(
               view,
               "#design-send-form textarea[data-submit=mod-enter-form][phx-hook=Editor]"
             )

      send_message(view, "改用 sonnet，推理强度 high")
      assert has_element?(view, "#design-messages [data-role=user]", "改用 sonnet，推理强度 high")
      refute view |> element("#design-send-form textarea") |> render() =~ "改用 sonnet"
      assert has_element?(view, "#design-turn-phase", "排队中")
    end

    test "有当前轮时不能发送", ctx do
      start!(ctx)
      {view, _} = open_page(ctx)

      assert has_element?(
               view,
               "#design-send-form textarea[disabled][placeholder*='等 helper 回复完']"
             )

      assert has_element?(view, "#design-send[disabled]")
    end

    test "超过 8 KB", ctx do
      design = start!(ctx)
      reply!(design.id, "好")
      {view, _} = open_page(ctx)

      view
      |> form("#design-send-form", %{"message" => String.duplicate("a", 9000)})
      |> render_change()

      assert has_element?(view, "[id$=-size][data-over=true]", "8.8 KB / 8 KB")
      assert has_element?(view, "#design-send[disabled]")
    end

    test "起草 Agent 已停用", ctx do
      design = start!(ctx)
      reply!(design.id, "好")
      {view, _} = open_page(ctx)
      {:ok, _} = Agents.disable(ctx.alice_scope, "helper")
      send_message(view, "还在吗")

      assert has_element?(view, "#design-send-warning", "helper 现在不能启动")
      assert has_element?(view, "#design-send-warning", "已停用")
      assert has_element?(view, "#design-send-warning-change", "更换")
      assert view |> element("#design-send-form textarea") |> render() =~ "还在吗"
      assert user_messages(design.id) == 1
    end

    test "达到 40 条", ctx do
      design = start!(ctx)
      reply!(design.id, "好")

      for i <- 2..40 do
        {:ok, _} = AgentDesigns.send(ctx.alice_scope, design.id, "第 #{i} 条")
        reply!(design.id, "收到")
      end

      {view, _} = open_page(ctx)

      assert has_element?(
               view,
               "#design-send-form textarea[disabled][placeholder*='已达 40 条消息上限，请确认或放弃这个对话']"
             )

      assert has_element?(view, "#design-count", "40 / 40")
    end
  end

  describe "更换起草 Agent" do
    test "更换起草 Agent", ctx do
      design = start!(ctx)
      propose!(design.id, %{"name" => "fe-dev"})
      reply!(design.id, "好")
      managed_agent_fixture(ctx.alice_scope, %{name: "codex-helper", provider: "codex"})
      {view, _} = open_page(ctx)

      assert has_element?(view, "#design-helper-menu-trigger")
      render_click(view, "change_helper", %{"name" => "codex-helper"})

      assert has_element?(view, "#design-helper[data-helper=codex-helper]")
      assert has_element?(view, "[data-code=helper_changed]", "起草 Agent 换成了 codex-helper")
      assert has_element?(view, "#design-messages [data-role=user]", "帮我建一个前端开发 Agent")
      assert has_element?(view, "#draft-agent-0[data-name=fe-dev]")
      assert has_element?(view, "#design-send-form", "回复会进入 codex-helper 的执行记录")
    end

    test "当前轮进行中", ctx do
      start!(ctx)
      {view, _} = open_page(ctx)
      refute has_element?(view, "#design-helper-menu-trigger")
      assert has_element?(view, "#design-helper-change-busy[aria-disabled=true]")
      assert has_element?(view, "#design-helper-change-busy-reason", "等这一轮结束后再更换")
    end
  end

  describe "确认创建" do
    defp ready(ctx, agents) do
      design = start!(ctx)
      for a <- agents, do: propose!(design.id, a)
      reply!(design.id, "可以确认了")
      design
    end

    test "一次创建两个 Agent", ctx do
      ready(ctx, [%{"name" => "fe-dev"}, %{"name" => "pr-reviewer"}])
      {view, _} = open_page(ctx)

      view |> element("#design-confirm-open") |> render_click()
      assert in_portal?(view, "design-confirm", "#design-confirm-list [data-name=fe-dev]")

      {:error, {:live_redirect, %{to: to}}} = result = confirm_now(view)
      {:ok, _index, html} = follow_redirect(result, log_in_user(build_conn(), ctx.alice))
      assert html =~ "已创建 2 个 Agent"

      assert to == "/w/#{ctx.ws.slug}/agents"
      {:ok, fe} = Agents.get(ctx.alice_scope, "fe-dev")
      assert fe.owner.id == ctx.alice.id
      assert {:ok, _} = Agents.get(ctx.alice_scope, "pr-reviewer")
    end

    test "创建一个 Agent", ctx do
      ready(ctx, [%{"name" => "fe-dev"}])
      {view, _} = open_page(ctx)
      view |> element("#design-confirm-open") |> render_click()

      assert {:error, {:live_redirect, %{to: to}}} = result = confirm_now(view)
      assert to == "/w/#{ctx.ws.slug}/agents/fe-dev"

      {:ok, _show, html} = follow_redirect(result, log_in_user(build_conn(), ctx.alice))
      assert html =~ "已创建 fe-dev"
    end

    test "确认对话框里的醒目取值", ctx do
      ready(ctx, [%{"name" => "architect", "capabilities" => ["create_tasks"]}])
      {view, _} = open_page(ctx)
      view |> element("#design-confirm-open") |> render_click()

      assert in_portal?(
               view,
               "design-confirm",
               "[data-name=architect] [data-warn=create_tasks]",
               "可以建任务"
             )

      assert in_portal?(view, "design-confirm", "p", "环境变量、额外 MCP 服务器、追加参数与指定成员请在创建后")
    end

    test "名字被抢先占用", ctx do
      ready(ctx, [%{"name" => "fe-dev"}, %{"name" => "pr-reviewer"}])
      {view, _} = open_page(ctx)
      view |> element("#design-confirm-open") |> render_click()
      managed_agent_fixture(ctx.bob_scope, %{name: "pr-reviewer"})
      confirm_now(view)

      assert has_element?(view, "#design-invalid", "1 个 Agent 未通过校验，没有创建任何 Agent")
      assert has_element?(view, "#draft-agent-1[data-name=pr-reviewer] [role=alert]", "名字")
      refute has_element?(view, "#draft-agent-0 [role=alert]")
      assert {:error, :not_found} = Agents.get(ctx.alice_scope, "fe-dev")

      # The errors go to the fields of the edit panel.
      view |> element("#draft-agent-1-edit") |> render_click()
      assert in_portal?(view, "agent-panel", "#agent-form-basic", "已被")
    end

    test "有当前轮", ctx do
      design = ready(ctx, [%{"name" => "fe-dev"}])
      {:ok, _} = AgentDesigns.send(ctx.alice_scope, design.id, "再改改")
      {view, _} = open_page(ctx)
      assert has_element?(view, "#design-confirm-open[aria-disabled=true]")
      assert has_element?(view, "#design-confirm-open-reason", "等 helper 回复完再确认")
    end

    test "an empty draft cannot be confirmed", ctx do
      design = start!(ctx)
      reply!(design.id, "好")
      {view, _} = open_page(ctx)
      assert has_element?(view, "#design-confirm-open-reason", "草稿里还没有 Agent")
    end

    test "确认期间草稿被修改, then 重新确认得到最新配置", ctx do
      design = ready(ctx, [%{"name" => "architect"}])
      {tab_a, _} = open_page(ctx)
      {tab_b, _} = open_page(ctx)
      old_version = version(design.id)

      tab_a |> element("#design-confirm-open") |> render_click()
      assert open?(tab_a, "design-confirm")
      refute in_portal?(tab_a, "design-confirm", "[data-warn]")

      # Tab B makes architect workspace-wide with create_tasks.
      tab_b |> element("#draft-agent-0-edit") |> render_click()

      render_submit(tab_b, "agent_form_submit", %{
        "agent" => %{"access" => "workspace", "capabilities" => ["", "create_tasks"]}
      })

      html = render(tab_a)
      refute open?(tab_a, "design-confirm")
      assert html =~ "草稿刚被更新，请检查后再确认"

      # The old snapshot's submit creates nothing.
      render_click(tab_a, "confirm", %{"version" => to_string(old_version)})
      assert {:error, :not_found} = Agents.get(ctx.alice_scope, "architect")

      tab_a |> element("#design-confirm-open") |> render_click()
      assert in_portal?(tab_a, "design-confirm", "[data-warn=access]", "工作区所有成员")
      assert in_portal?(tab_a, "design-confirm", "[data-warn=create_tasks]", "可以建任务")

      {:error, {:live_redirect, _}} =
        confirm_now(tab_a)

      {:ok, architect} = Agents.get(ctx.alice_scope, "architect")
      assert architect.access == "workspace"
      assert architect.capabilities == ["create_tasks"]
    end
  end

  describe "放弃与关闭说明" do
    test "放弃", ctx do
      design = ready(ctx, [%{"name" => "fe-dev"}])
      {view, _} = open_page(ctx)
      view |> element("#design-discard-open") |> render_click()
      assert open?(view, "design-discard")
      render_click(view, "dismiss_discard", %{})
      html = render_click(view, "discard", %{})

      assert html =~ "已放弃对话"
      assert has_element?(view, "#design-start")
      assert design!(design.id).status == :discarded
      assert {:error, :not_found} = Agents.get(ctx.alice_scope, "fe-dev")
    end

    test "另一个标签页确认了", ctx do
      ready(ctx, [%{"name" => "fe-dev"}])
      {tab_a, _} = open_page(ctx)
      {tab_b, _} = open_page(ctx)

      tab_a |> element("#design-confirm-open") |> render_click()
      {:error, {:live_redirect, _}} = confirm_now(tab_a)

      assert has_element?(tab_b, "#design-closed[data-status=confirmed]", "这个对话已确认，创建了")

      assert has_element?(
               tab_b,
               ~s(#design-closed a[href="/w/#{ctx.ws.slug}/agents/fe-dev"]),
               "fe-dev"
             )

      refute has_element?(tab_b, "#design-send-form")
      assert has_element?(tab_b, "#draft-agent-0-edit[aria-disabled=true]")
      refute has_element?(tab_b, "#design-confirm-open")
    end

    test "对话过期, then a new conversation", ctx do
      design = start!(ctx)
      {view, _} = open_page(ctx)
      expire!(design.id)

      assert has_element?(view, "#design-closed[data-status=expired]", "这个对话 7 天没有活动，已过期")
      view |> element("#design-new") |> render_click()
      assert has_element?(view, "#design-start")
    end

    test "对话已不存在", ctx do
      design = start!(ctx)
      {view, _} = open_page(ctx)
      delete!(design.id)
      assert render(view) =~ "对话已不存在"
      assert has_element?(view, "#design-start")
    end
  end

  describe "对话创建页实时同步" do
    test "两个标签页", ctx do
      design = ready(ctx, [%{"name" => "fe-dev"}, %{"name" => "qa"}])
      {tab_a, _} = open_page(ctx)
      {tab_b, _} = open_page(ctx)

      tab_a |> element("#draft-agent-1-remove") |> render_click()
      render_click(tab_a, "dismiss_remove", %{})
      render_click(tab_a, "remove", %{"name" => "qa"})
      send_message(tab_a, "去掉了 qa")

      refute has_element?(tab_b, "[data-name=qa]")
      assert has_element?(tab_b, "#design-draft-count", "1 / 8 个 Agent")
      assert has_element?(tab_b, "#design-messages [data-role=user]", "去掉了 qa")
      assert has_element?(tab_b, "#design-turn-phase", "排队中")
      assert design!(design.id).current_run_id
    end

    test "运行时离线", ctx do
      design = start!(ctx)
      runtime_id = profile(agent_actor(ctx.ws, "helper")).runtime_id
      propose!(design.id, %{"name" => "fe-dev", "runtime_id" => runtime_id})
      reply!(design.id, "好")
      set_runtime_status!(runtime_id, "online")
      {view, _} = open_page(ctx)
      assert has_element?(view, "#draft-agent-0 [data-field=runtime_id]", "在线")

      set_runtime_status!(runtime_id, "offline")
      send(view.pid, {:runtimes_changed})
      assert has_element?(view, "#draft-agent-0 [data-field=runtime_id]", "离线")
    end
  end

  describe "对话创建页的布局" do
    test "窄屏: two tabs, 对话 by default", ctx do
      design = start!(ctx)
      propose!(design.id, %{"name" => "fe-dev"})
      propose!(design.id, %{"name" => "qa"})
      {view, _} = open_page(ctx)

      assert has_element?(
               view,
               "#design-tabs.lg\\:hidden #design-tab-chat[aria-current=page]",
               "对话"
             )

      assert has_element?(view, "#design-tab-draft", "草稿（2）")
      assert has_element?(view, "#design-draft.max-lg\\:hidden")
      refute has_element?(view, "#design-chat.max-lg\\:hidden")
    end

    # code-review-2 P2-1: below lg the grid is one shrinkable column, so wide content
    # (names, badges, actions) cannot push the draft column past the viewport. The
    # sizes themselves are measured in a browser (impl-notes-1, walk-3).
    test "窄屏: one shrinkable column, columns may shrink", ctx do
      start!(ctx)
      {view, _} = open_page(ctx)
      assert has_element?(view, ~s{#design-columns[class~="grid-cols-[minmax(0,1fr)]"]})
      assert has_element?(view, "#design-chat.min-w-0")
      assert has_element?(view, "#design-draft.min-w-0")
    end

    test "草稿变化提示", ctx do
      design = start!(ctx)
      {view, _} = open_page(ctx)
      refute has_element?(view, "#design-tab-draft-dot")

      propose!(design.id, %{"name" => "fe-dev"})
      assert has_element?(view, "#design-tab-draft-dot")

      view |> element("#design-tab-draft") |> render_click()
      refute has_element?(view, "#design-tab-draft-dot")
      assert has_element?(view, "#design-chat.max-lg\\:hidden")
    end

    test "the conversation follows its end with 跳到最新 (shared with the execution log)", ctx do
      start!(ctx)
      {view, _} = open_page(ctx)

      assert has_element?(
               view,
               ~s(#design-messages[phx-hook$="RunLogScroll"][data-jump="#design-jump"])
             )

      assert has_element?(view, "#design-jump", "跳到最新")
    end
  end

  describe "对话创建页不暴露密钥" do
    test "起草 Agent 绑定了密钥", ctx do
      key = "sk-sentinel-#{System.unique_integer([:positive])}"
      env = "env-sentinel-#{System.unique_integer([:positive])}"

      zai =
        provider_account_fixture(ctx.alice, %{
          name: "zai",
          api_key: key,
          base_url: "https://api.z.ai/api/anthropic"
        })

      {:ok, _} =
        Agents.update(ctx.alice_scope, "helper", %{
          provider_account_id: zai.id,
          env: %{"FOO" => env}
        })

      {view, _} = open_page(ctx)

      view
      |> form("#design-start-form", %{"message" => "你好", "helper" => "helper"})
      |> render_submit()

      {:ok, %{id: id}} = AgentDesigns.current(ctx.alice_scope)
      reply!(id, "好")
      view |> element("#design-add-empty") |> render_click()
      assert open?(view, "agent-panel")

      for html <- [render(view), view |> portal("agent-panel") |> LazyHTML.to_html()] do
        refute html =~ key
        refute html =~ env
      end

      refute state(view) =~ key
      refute state(view) =~ env
    end
  end

  # The dialog's primary button: its on_cancel, then `confirm` with the snapshot version.
  defp confirm_now(view) do
    [%{"value" => %{"version" => version}}] =
      view
      |> portal_attr("design-confirm", "[data-confirm-primary]", "phx-click")
      |> Jason.decode!()
      |> Enum.map(fn [_op, args] -> args end)
      |> Enum.filter(&(&1["event"] == "confirm"))

    render_click(view, "dismiss_confirm", %{})
    render_click(view, "confirm", %{"version" => to_string(version)})
  end

  # The turn's run was created 11 minutes ago: the minute check cancels it.
  defp queue_timeout!(design_id) do
    old = DateTime.add(DateTime.utc_now(), -11, :minute)
    run_id = design!(design_id).current_run_id
    Repo.update_all(from(r in Helmsman.Runs.Run, where: r.id == ^run_id), set: [inserted_at: old])
    AgentDesigns.sweep_queued()
  end

  defp set_runtime_status!(id, status),
    do: Repo.update_all(from(r in Runtime, where: r.id == ^id), set: [status: status])
end
