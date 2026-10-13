defmodule HelmsmanWeb.AgentDesignDraftTest do
  @moduledoc """
  Spec web-agent-design 草稿卡片 and 修改草稿 (add-agent-conversation-ui D6, D7): the
  cards of the draft, the draft panel (`AgentForm` `:draft_new` / `:draft_edit`), its
  three-way merge after a `stale` save, removal and the limit.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.AgentDesignHelpers
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures

  alias Helmsman.{AgentDesigns, Runtimes}

  setup :design_setup

  setup ctx do
    {daemon, _token} = daemon_fixture(ctx.alice, %{name: "alice-mbp", workspace_ids: [ctx.ws.id]})

    mbp =
      runtime_fixture(ctx.ws, daemon, %{
        provider: "claude",
        models: ["sonnet", "opus"],
        efforts: ["medium", "high"]
      })

    %{mbp: mbp}
  end

  # A conversation whose turn ended with the agents `attrs` in its draft.
  defp drafted(ctx, attrs) do
    design = start!(ctx)
    for a <- List.wrap(attrs), do: propose!(design.id, a)
    reply!(design.id, "看看草稿")
    design
  end

  defp card(view, i), do: view |> element("#draft-agent-#{i}") |> render()

  defp save(view, params), do: render_submit(view, "agent_form_submit", %{"agent" => params})

  describe "草稿卡片" do
    test "AI 提出的 Agent 出现在草稿里", ctx do
      design = start!(ctx)
      {view, _} = open_page(ctx)

      propose!(design.id, %{
        "name" => "fe-dev",
        "runtime_id" => ctx.mbp.id,
        "model" => "sonnet",
        "effort" => "high"
      })

      assert has_element?(view, "#draft-agent-0[data-name=fe-dev]")
      assert has_element?(view, "#draft-agent-0 [data-field=provider]", "Claude Code")
      assert has_element?(view, "#draft-agent-0 [data-field=runtime_id]", "alice-mbp · 在线")
      assert has_element?(view, "#draft-agent-0 [data-field=model]", "sonnet")
      assert has_element?(view, "#draft-agent-0 [data-field=effort]", "high")
      assert has_element?(view, "#draft-agent-0 [data-updated-by=ai]", "AI 修改")
      assert has_element?(view, "#design-draft-count", "1 / 8 个 Agent")
    end

    test "醒目的访问与能力", ctx do
      drafted(ctx, %{
        "name" => "architect",
        "access" => "workspace",
        "capabilities" => ["create_tasks"]
      })

      {view, _} = open_page(ctx)

      assert has_element?(view, "#draft-agent-0 [data-warn=access]", "工作区所有成员")

      assert has_element?(
               view,
               "#draft-agent-0 [data-warn-note=access]",
               "工作区所有成员都能触发这个 Agent，在你的机器上运行"
             )

      assert has_element?(view, "#draft-agent-0 [data-warn=create_tasks]", "可以建任务")
      assert has_element?(view, "#draft-agent-0 [data-warn-note=create_tasks]", "它能在工作区里新建任务并指派")
    end

    test "defaults: 仅你, 只能更新自己的任务, CLI 默认登录, CLI 缺省, 缺省", ctx do
      drafted(ctx, %{"name" => "plain"})
      {view, _} = open_page(ctx)
      html = card(view, 0)

      for text <- [
            "仅你",
            "只能更新自己的任务",
            "CLI 默认登录",
            "CLI 缺省",
            "缺省",
            "不绑定",
            "并发 2 · 总时长 120 分钟 · 无输出 20 分钟"
          ],
          do: assert(html =~ text)

      refute html =~ "data-warn="
    end

    test "指令折叠", ctx do
      instructions = "# 前端约定\n\n" <> String.duplicate("使用 Tailwind 编写样式。\n", 70)
      size = :erlang.float_to_binary(byte_size(instructions) / 1024, decimals: 1)
      drafted(ctx, %{"name" => "fe-dev", "instructions" => instructions})
      {view, _} = open_page(ctx)

      assert has_element?(view, "#draft-agent-0 details[data-field=instructions]:not([open])")
      assert has_element?(view, "#draft-agent-0 details summary", "指令（#{size} KB）")
      assert has_element?(view, "#draft-agent-0 details h1", "前端约定")
    end

    test "运行时与账号: someone else's or disabled runtimes and unknown accounts are unavailable",
         ctx do
      {bob_daemon, _} = daemon_fixture(ctx.bob, %{name: "bob-box", workspace_ids: [ctx.ws.id]})
      bob_rt = runtime_fixture(ctx.ws, bob_daemon)
      {:ok, _} = Runtimes.disable(ctx.alice_scope, ctx.mbp.id)
      zai = provider_account_fixture(ctx.alice, %{name: "zai"})

      design = drafted(ctx, [])
      base = %{"provider" => "claude", "instructions" => "做前端。", "updated_by" => "ai"}

      # Bindings the domain checked once and that changed since (or data from before).
      put_draft!(design.id, [
        Map.merge(base, %{"name" => "a", "runtime_id" => bob_rt.id}),
        Map.merge(base, %{
          "name" => "b",
          "runtime_id" => ctx.mbp.id,
          "provider_account_id" => zai.id
        }),
        Map.merge(base, %{"name" => "c", "provider_account_id" => zai.id + 100_000})
      ])

      {view, _} = open_page(ctx)

      assert has_element?(
               view,
               "#draft-agent-0 [data-field=runtime_id] .text-warning-fg",
               "运行时 ##{bob_rt.id}（不可用）"
             )

      refute card(view, 0) =~ "bob-box"

      assert has_element?(
               view,
               "#draft-agent-1 [data-field=runtime_id]",
               "运行时 ##{ctx.mbp.id}（不可用）"
             )

      assert has_element?(view, "#draft-agent-1 [data-field=provider_account_id]", "zai")
      assert has_element?(view, "#draft-agent-1 [data-field=model]", "账号缺省")
      assert has_element?(view, "#draft-agent-2 [data-field=provider_account_id]", "（不可用）")
    end

    test "待告知修改", ctx do
      design = drafted(ctx, %{"name" => "fe-dev", "effort" => "high"})
      {view, _} = open_page(ctx)
      refute has_element?(view, "#design-pending")

      view |> element("#draft-agent-0-edit") |> render_click()
      save(view, %{"effort" => "medium"})

      assert has_element?(view, "#design-pending", "这些修改会在你下一条消息时告诉 AI：")
      assert has_element?(view, "#design-pending", "fe-dev（推理强度）")
      assert has_element?(view, "#draft-agent-0 [data-updated-by=user]", "你修改")

      view |> form("#design-send-form", %{"message" => "我改了推理强度"}) |> render_submit()
      refute has_element?(view, "#design-pending")
      assert design!(design.id).pending_edits == []
    end

    test "the cards whose content changed are highlighted, each version anew", ctx do
      design = drafted(ctx, [%{"name" => "fe-dev"}, %{"name" => "qa"}])
      {view, _} = open_page(ctx)
      refute card(view, 0) =~ "animate-draft-ring"

      {:ok, _} = AgentDesigns.send(ctx.alice_scope, design.id, "改模型")
      propose!(design.id, %{"name" => "fe-dev", "model" => "opus"})
      first = card(view, 0)
      assert first =~ "motion-safe:animate-draft-ring-"
      refute card(view, 1) =~ "animate-draft-ring"

      propose!(design.id, %{"name" => "fe-dev", "model" => "sonnet"})
      [_, a] = Regex.run(~r/animate-draft-ring-(a|b)/, first)
      [_, b] = Regex.run(~r/animate-draft-ring-(a|b)/, card(view, 0))
      assert a != b
    end

    test "空状态", ctx do
      design = start!(ctx)
      reply!(design.id, "好")
      {view, _} = open_page(ctx)
      assert has_element?(view, "#design-draft-empty", "AI 提出的 Agent 会出现在这里。你也可以直接添加。")
      assert has_element?(view, "#design-add-empty", "添加 Agent")
    end
  end

  describe "修改草稿" do
    test "改模型", ctx do
      design =
        drafted(ctx, %{"name" => "fe-dev", "runtime_id" => ctx.mbp.id, "model" => "sonnet"})

      {view, _} = open_page(ctx)
      view |> element("#draft-agent-0-edit") |> render_click()

      assert in_portal?(view, "agent-panel", "#agent-panel-title", "编辑 fe-dev")
      assert in_portal?(view, "agent-panel", "#agent-form-submit", "保存到草稿")
      save(view, %{"model" => "opus"})

      refute open?(view, "agent-panel")
      assert has_element?(view, "#draft-agent-0 [data-field=model]", "opus")
      assert has_element?(view, "#draft-agent-0 [data-updated-by=user]", "你修改")
      assert entry(design.id, "fe-dev")["runtime_id"] == ctx.mbp.id
    end

    test "面板里没有密钥类字段", ctx do
      drafted(ctx, [])
      {view, _} = open_page(ctx)
      view |> element("#design-add-empty") |> render_click()
      panel = view |> portal("agent-panel") |> LazyHTML.to_html()

      assert panel =~ "添加 Agent"

      for id <-
            ~w(agent-form-secrets agent-custom-args agent-access-members agent-wake-on-requested),
          do: refute(panel =~ ~s(id="#{id}"))

      refute panel =~ "type=\"password\""

      options =
        view
        |> portal("agent-panel")
        |> LazyHTML.query("#agent-access option")
        |> Enum.map(&LazyHTML.attribute(&1, "value"))
        |> List.flatten()

      assert options == ["owner_only", "workspace"]
      assert in_portal?(view, "agent-panel", "#agent-capability-create-tasks")
      assert in_portal?(view, "agent-panel", "#agent-form-draft-note", "请在创建后到 Agent 的编辑面板设置")
      assert in_portal?(view, "agent-panel", "#agent-name")
    end

    test "添加 Agent", ctx do
      design = drafted(ctx, [])
      {view, _} = open_page(ctx)
      view |> element("#design-add-empty") |> render_click()

      save(view, %{
        "name" => "qa",
        "provider" => "claude",
        "runtime_id" => to_string(ctx.mbp.id),
        "instructions" => "做测试。"
      })

      refute open?(view, "agent-panel")
      assert has_element?(view, "#draft-agent-0[data-name=qa] [data-updated-by=user]")
      assert entry(design.id, "qa")["runtime_id"] == ctx.mbp.id
    end

    test "校验错误", ctx do
      managed_agent_fixture(ctx.alice_scope, %{name: "dev"})
      drafted(ctx, %{"name" => "fe-dev"})
      {view, _} = open_page(ctx)
      view |> element("#draft-agent-0-edit") |> render_click()
      save(view, %{"name" => "dev"})

      assert open?(view, "agent-panel")
      assert in_portal?(view, "agent-panel", "#agent-form-basic", "已被")
      assert has_element?(view, "#draft-agent-0[data-name=fe-dev]")
    end

    test "保存时草稿已被更新", ctx do
      design =
        drafted(ctx, %{
          "name" => "fe-dev",
          "description" => "旧描述",
          "effort" => "high",
          "runtime_id" => ctx.mbp.id
        })

      {tab_a, _} = open_page(ctx)
      {tab_b, _} = open_page(ctx)
      tab_a |> element("#draft-agent-0-edit") |> render_click()

      tab_b |> element("#draft-agent-0-edit") |> render_click()
      save(tab_b, %{"description" => "另一个标签页的描述"})

      save(tab_a, %{"effort" => "medium"})
      assert open?(tab_a, "agent-panel")
      assert in_portal?(tab_a, "agent-panel", "#agent-form-notice", "草稿刚被更新")

      assert portal_attr(tab_a, "agent-panel", "#agent-effort option[selected]", "value") ==
               "medium"

      assert in_portal?(tab_a, "agent-panel", "#agent-description", "另一个标签页的描述")

      # The form keeps the merged params; a second save sends only the effort.
      save(tab_a, %{"effort" => "medium", "description" => "另一个标签页的描述"})
      refute open?(tab_a, "agent-panel")
      fe = entry(design.id, "fe-dev")
      assert fe["effort"] == "medium"
      assert fe["description"] == "另一个标签页的描述"
    end

    test "保存时草稿 Agent 已被移除: the save adds it again", ctx do
      design = drafted(ctx, [%{"name" => "fe-dev"}, %{"name" => "qa"}])
      {tab_a, _} = open_page(ctx)
      tab_a |> element("#draft-agent-1-edit") |> render_click()
      {:ok, _} = AgentDesigns.remove_agent(ctx.alice_scope, design.id, version(design.id), "qa")

      save(tab_a, %{"description" => "回来"})
      assert in_portal?(tab_a, "agent-panel", "#agent-form-notice", "qa 已从草稿移除，保存会重新加入")
      save(tab_a, %{"description" => "回来"})
      assert entry(design.id, "qa")["description"] == "回来"
    end

    test "当前轮开始后不能保存", ctx do
      design = drafted(ctx, %{"name" => "fe-dev"})
      {tab_a, _} = open_page(ctx)
      tab_a |> element("#draft-agent-0-edit") |> render_click()
      render_change(tab_a, "agent_form_change", %{"agent" => %{"description" => "正在写"}})

      {:ok, _} = AgentDesigns.send(ctx.alice_scope, design.id, "另一个标签页发的")

      assert in_portal?(
               tab_a,
               "agent-panel",
               "#agent-form-locked-notice",
               "helper 正在回复，回复结束后才能保存"
             )

      assert portal_attr(tab_a, "agent-panel", "#agent-form-submit", "disabled") != nil
      assert in_portal?(tab_a, "agent-panel", "#agent-description", "正在写")

      reply!(design.id, "好")
      refute in_portal?(tab_a, "agent-panel", "#agent-form-locked-notice")
      assert portal_attr(tab_a, "agent-panel", "#agent-form-submit", "disabled") == nil
      assert in_portal?(tab_a, "agent-panel", "#agent-description", "正在写")
    end

    # code-review-1 P2-1: the open panel follows runtime changes, keeping the input.
    test "运行时变化刷新已打开面板的选项", ctx do
      drafted(ctx, %{"name" => "fe-dev", "runtime_id" => ctx.mbp.id})
      {view, _} = open_page(ctx)
      view |> element("#draft-agent-0-edit") |> render_click()
      render_change(view, "agent_form_change", %{"agent" => %{"description" => "正在写"}})
      assert in_portal?(view, "agent-panel", "#agent-runtime option[selected]", "alice-mbp · 在线")

      {daemon, _} = daemon_fixture(ctx.alice, %{name: "alice-new", workspace_ids: [ctx.ws.id]})
      runtime_fixture(ctx.ws, daemon)
      {:ok, _} = Runtimes.disable(ctx.alice_scope, ctx.mbp.id)
      send(view.pid, {:runtimes_changed})

      assert in_portal?(
               view,
               "agent-panel",
               "#agent-runtime option[selected]",
               "运行时 ##{ctx.mbp.id}（不可用）"
             )

      assert in_portal?(view, "agent-panel", "#agent-runtime option", "alice-new · 在线")
      assert has_element?(view, "#draft-agent-0 [data-field=runtime_id]", "（不可用）")
      assert in_portal?(view, "agent-panel", "#agent-description", "正在写")
    end

    test "有当前轮时卡片只读", ctx do
      design = drafted(ctx, %{"name" => "fe-dev"})
      {:ok, _} = AgentDesigns.send(ctx.alice_scope, design.id, "继续")
      {view, _} = open_page(ctx)

      assert has_element?(view, "#draft-agent-0-edit[aria-disabled=true]")
      assert has_element?(view, "#draft-agent-0-remove[aria-disabled=true]")
      assert has_element?(view, "#draft-agent-0-edit-reason", "等 helper 回复完再修改")
      assert has_element?(view, "#design-add[aria-disabled=true]")
    end

    test "移除", ctx do
      design = drafted(ctx, [%{"name" => "fe-dev"}, %{"name" => "qa"}])
      {view, _} = open_page(ctx)
      view |> element("#draft-agent-1-remove") |> render_click()

      assert open?(view, "design-remove")
      assert in_portal?(view, "design-remove", "#design-remove-title", "从草稿移除 qa？")
      render_click(view, "dismiss_remove", %{})
      render_click(view, "remove", %{"name" => "qa"})

      refute has_element?(view, "[data-name=qa]")
      assert has_element?(view, "#design-draft-count", "1 / 8 个 Agent")
      assert entry(design.id, "qa") == nil
    end

    test "草稿已满", ctx do
      drafted(ctx, for(i <- 1..8, do: %{"name" => "a#{i}"}))
      {view, _} = open_page(ctx)
      assert has_element?(view, "#design-add[aria-disabled=true]")
      assert has_element?(view, "#design-add-reason", "草稿最多 8 个 Agent")
    end
  end
end
