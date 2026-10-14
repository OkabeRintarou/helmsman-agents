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

    # The buttons keep their click while usable: a `false` disabled_reason makes `<.button>`
    # inert in the browser, which pushed events do not show (code-reply-7).
    test "添加 Agent and the card actions are live while the draft is open", ctx do
      drafted(ctx, %{"name" => "fe-dev"})
      {view, _} = open_page(ctx)

      for id <- ~w(design-add draft-agent-0-edit draft-agent-0-remove design-confirm-open) do
        assert has_element?(view, "##{id}[phx-click]"), id
        refute has_element?(view, "##{id}[data-hm-disabled]"), id
        refute has_element?(view, "##{id}[aria-disabled]"), id
      end

      view |> element("#design-add") |> render_click()
      assert open?(view, "agent-panel")
    end

    test "草稿已满", ctx do
      drafted(ctx, for(i <- 1..8, do: %{"name" => "a#{i}"}))
      {view, _} = open_page(ctx)
      assert has_element?(view, "#design-add[aria-disabled=true]")
      assert has_element?(view, "#design-add-reason", "草稿最多 8 个 Agent")
    end
  end

  # add-squads-autopilots-ui D16: the squad part of a squad conversation.
  defp squad_drafted(ctx, agents, squad) do
    design = start_squad!(ctx)
    for a <- agents, do: propose!(design.id, a)
    if squad, do: propose_squad!(design.id, squad)
    reply!(design.id, "看看小队")
    design
  end

  defp save_squad(view, params),
    do: render_submit(view, "squad_form_submit", %{"squad" => params})

  describe "小队草稿" do
    test "AI 提出小队", ctx do
      bob = actor_name(ctx.ws, ctx.bob)
      design = start_squad!(ctx)
      {view, _} = open_page(ctx)
      assert has_element?(view, "#design-squad [data-field=name]", "未命名")

      propose!(design.id, %{"name" => "web-lead"})
      propose!(design.id, %{"name" => "fe-dev"})

      propose_squad!(design.id, %{
        "name" => "web-team",
        "description" => "做网页",
        "leader" => "web-lead",
        "instructions" => "按 **顺序** 分工",
        "members" => [
          %{"name" => "fe-dev", "role_note" => "写前端"},
          %{"name" => bob, "role_note" => "拍板产品问题"}
        ]
      })

      assert has_element?(view, "#design-squad[data-name=web-team] [data-field=name]", "web-team")
      assert has_element?(view, "#design-squad [data-updated-by=ai]", "AI 修改")
      assert has_element?(view, "#design-squad [data-field=description]", "做网页")
      assert has_element?(view, "#design-squad [data-field=leader]", "web-lead")
      assert has_element?(view, "#design-squad [data-field=leader] [data-origin=new]", "新")

      assert has_element?(view, "#design-squad-member-0[data-member=fe-dev]", "写前端")
      assert has_element?(view, "#design-squad-member-0 [data-origin=new]", "新")
      assert has_element?(view, "#design-squad-member-0 [data-kind]", "托管 Agent")
      assert has_element?(view, ~s(#design-squad-member-1[data-member="#{bob}"]), "拍板产品问题")
      assert has_element?(view, "#design-squad-member-1 [data-origin=existing]", "已有")
      assert has_element?(view, "#design-squad-member-1 [data-kind]", "人")
      assert has_element?(view, "#design-squad-trigger", "能触发这个小队的成员")
      refute has_element?(view, "#design-squad-missing")

      # The instructions: sanitised Markdown, folded, with their size.
      assert has_element?(view, "#design-squad details[data-field=instructions] summary", "说明（")
      refute has_element?(view, "#design-squad details[open]")
      assert has_element?(view, "#design-squad details strong", "顺序")

      # The cards are below the block.
      html = view |> element("#design-draft") |> render()
      {squad_at, _} = :binary.match(html, ~s(id="design-squad"))
      {card_at, _} = :binary.match(html, ~s(id="draft-agent-0"))
      assert squad_at < card_at
    end

    test "受限成员", ctx do
      managed_agent_fixture(ctx.alice_scope, %{name: "keel/qa", access: "owner_only"})
      managed_agent_fixture(ctx.alice_scope, %{name: "keel/lead", access: "workspace"})

      squad_drafted(ctx, [], %{
        "name" => "web-team",
        "leader" => "keel/lead",
        "members" => [%{"name" => "keel/qa", "role_note" => "测试"}]
      })

      {view, _} = open_page(ctx)
      assert has_element?(view, "#design-squad-trigger-box[data-warn=restricted]")
      assert has_element?(view, "#design-squad-trigger", ~r/能触发这个小队的成员 1 \/ 2/)
      assert has_element?(view, "#design-squad-trigger [data-restricted]", "keel/qa")
      assert has_element?(view, "#design-squad-member-0 [data-origin=existing]", "已有")
    end

    test "编辑小队 is live without a turn", ctx do
      squad_drafted(ctx, [%{"name" => "web-lead"}], %{
        "name" => "web-team",
        "leader" => "web-lead"
      })

      {view, _} = open_page(ctx)
      assert has_element?(view, "#design-squad-edit[phx-click]")
      refute has_element?(view, "#design-squad-edit[data-hm-disabled]")
      assert has_element?(view, "#draft-agent-0-remove[data-hm-disabled]")
      assert has_element?(view, "#draft-agent-0-edit[phx-click]")
      refute has_element?(view, "#draft-agent-0-edit[data-hm-disabled]")
    end

    test "Agent 对话没有小队区块", ctx do
      drafted(ctx, %{"name" => "fe-dev"})
      {view, _} = open_page(ctx)
      assert has_element?(view, "#draft-agent-0")
      refute has_element?(view, "#design-squad")
      refute has_element?(view, "#design-squad-edit")
    end
  end

  describe "修改小队草稿" do
    test "用户改成员说明", ctx do
      design =
        squad_drafted(ctx, [%{"name" => "web-lead"}, %{"name" => "qa"}], %{
          "name" => "web-team",
          "leader" => "web-lead",
          "members" => [%{"name" => "qa", "role_note" => "测试"}]
        })

      {view, _} = open_page(ctx)
      view |> element("#design-squad-edit") |> render_click()
      assert open?(view, "squad-panel")
      assert in_portal?(view, "squad-panel", "#squad-panel-title", "编辑小队")
      assert in_portal?(view, "squad-panel", "#squad-form-submit", "保存到草稿")

      assert in_portal?(
               view,
               "squad-panel",
               "#squad-form-member-0[data-member=qa] [data-origin=new]"
             )

      save_squad(view, %{"members" => %{"0" => %{"role_note" => "端到端测试"}}})

      refute open?(view, "squad-panel")
      assert has_element?(view, "#design-squad-member-0[data-member=qa]", "端到端测试")
      assert has_element?(view, "#design-squad [data-updated-by=user]", "你修改")
      assert has_element?(view, "#design-pending", "小队（成员）")

      squad = design!(design.id).draft["squad"]
      assert squad["members"] == [%{"name" => "qa", "role_note" => "端到端测试"}]
      assert squad["name"] == "web-team"
      assert squad["leader"] == "web-lead"
    end

    test "面板的 leader 候选里草稿新 Agent 在前并带「新」", ctx do
      managed_agent_fixture(ctx.alice_scope, %{name: "keel/lead"})
      managed_agent_fixture(ctx.bob_scope, %{name: "bob/lead"})
      squad_drafted(ctx, [%{"name" => "web-lead"}, %{"name" => "fe-dev"}], nil)
      {view, _} = open_page(ctx)
      view |> element("#design-squad-edit") |> render_click()

      options =
        view
        |> portal("squad-panel")
        |> LazyHTML.query("#squad-form-leader option")
        |> Enum.map(&{LazyHTML.attribute(&1, "value"), LazyHTML.text(&1)})
        |> Enum.reject(fn {[value], _} -> value == "" end)

      assert [{["web-lead"], "web-lead（新）"}, {["fe-dev"], "fe-dev（新）"} | existing] = options
      existing_names = Enum.map(existing, fn {[v], _} -> v end)
      assert "keel/lead" in existing_names
      assert "helper" in existing_names
      # The leader's owner is not checked in the draft: bob's agent is selectable.
      assert "bob/lead" in existing_names
      refute in_portal?(view, "squad-panel", "#squad-form-leader option[disabled]")

      # Members: the people and the draft's agents (新) too.
      assert in_portal?(
               view,
               "squad-panel",
               ~s(#squad-form-add option[value="fe-dev"]),
               "fe-dev（新）"
             )

      assert in_portal?(
               view,
               "squad-panel",
               ~s(#squad-form-add optgroup[label="人"] option),
               actor_name(ctx.ws, ctx.bob)
             )
    end

    # code-review-7 P2-2: the domain resolves the squad's names case-insensitively.
    test "references in another case: selected, kept when only the description changes",
         ctx do
      managed_agent_fixture(ctx.alice_scope, %{name: "keel/fe"})

      design =
        squad_drafted(ctx, [%{"name" => "web-lead"}, %{"name" => "qa"}], %{
          "name" => "web-team",
          "leader" => "WEB-LEAD",
          "members" => [
            %{"name" => "QA", "role_note" => "测试"},
            %{"name" => "KEEL/FE", "role_note" => "前端"}
          ]
        })

      assert design!(design.id).draft["squad"]["leader"] == "WEB-LEAD"
      {view, _} = open_page(ctx)
      view |> element("#design-squad-edit") |> render_click()

      assert portal_attr(view, "squad-panel", "#squad-form-leader option[selected]", "value") ==
               "web-lead"

      assert in_portal?(
               view,
               "squad-panel",
               "#squad-form-member-0[data-member=qa] [data-origin=new]"
             )

      assert in_portal?(view, "squad-panel", ~s(#squad-form-member-1[data-member="keel/fe"]))
      refute in_portal?(view, "squad-panel", "#squad-form-member-1 [data-origin=new]")

      assert portal_attr(
               view,
               "squad-panel",
               "#squad-form-member-1 [data-actor-kind]",
               "data-actor-kind"
             ) ==
               "agent"

      # The leader and the members are no candidates to add.
      for name <- ~w(web-lead qa keel/fe),
          do: refute(in_portal?(view, "squad-panel", ~s(#squad-form-add option[value="#{name}"])))

      save_squad(view, %{"description" => "新描述"})
      refute open?(view, "squad-panel")

      squad = design!(design.id).draft["squad"]
      assert squad["description"] == "新描述"
      assert squad["leader"] == "WEB-LEAD"

      assert squad["members"] == [
               %{"name" => "QA", "role_note" => "测试"},
               %{"name" => "KEEL/FE", "role_note" => "前端"}
             ]

      assert has_element?(view, "#design-pending", "小队（描述）")
    end

    test "a stale save merges references in another case as unchanged", ctx do
      design =
        squad_drafted(ctx, [%{"name" => "web-lead"}, %{"name" => "qa"}], %{
          "name" => "web-team",
          "leader" => "WEB-LEAD",
          "members" => [%{"name" => "QA", "role_note" => "测试"}]
        })

      {view, _} = open_page(ctx)
      view |> element("#design-squad-edit") |> render_click()

      {:ok, _} =
        AgentDesigns.put_squad(ctx.alice_scope, design.id, version(design.id), %{
          "members" => [%{"name" => "qa", "role_note" => "端到端测试"}]
        })

      save_squad(view, %{"description" => "新描述"})
      assert in_portal?(view, "squad-panel", "#squad-form-notice", "草稿刚被更新")
      assert in_portal?(view, "squad-panel", "#squad-form-member-0-note[value=端到端测试]")

      assert portal_attr(view, "squad-panel", "#squad-form-leader option[selected]", "value") ==
               "web-lead"

      save_squad(view, %{"description" => "新描述"})
      squad = design!(design.id).draft["squad"]
      assert squad["description"] == "新描述"
      assert squad["leader"] == "WEB-LEAD"
      assert squad["members"] == [%{"name" => "qa", "role_note" => "端到端测试"}]
    end

    test "校验错误 in the panel; the leader moves out of the members", ctx do
      design =
        squad_drafted(ctx, [%{"name" => "web-lead"}, %{"name" => "qa"}], %{
          "name" => "web-team",
          "members" => [%{"name" => "qa", "role_note" => ""}]
        })

      {view, _} = open_page(ctx)
      view |> element("#design-squad-edit") |> render_click()

      save_squad(view, %{"name" => "web-lead", "leader" => "web-lead"})
      assert open?(view, "squad-panel")
      assert in_portal?(view, "squad-panel", "#squad-form", "与草稿里的 Agent 重名")

      long = String.duplicate("a", 2049)
      save_squad(view, %{"name" => "web-team", "members" => %{"0" => %{"role_note" => long}}})

      assert in_portal?(
               view,
               "squad-panel",
               "#squad-form-member-0[data-member=qa]",
               "qa 的职责说明不能超过 2048 字节"
             )

      assert design!(design.id).draft["squad"]["leader"] == nil
    end

    test "保存时草稿已被更新: the latest loaded, the user's fields kept", ctx do
      design =
        squad_drafted(ctx, [%{"name" => "web-lead"}, %{"name" => "qa"}], %{
          "name" => "web-team",
          "description" => "旧描述",
          "members" => [%{"name" => "qa", "role_note" => "测试"}]
        })

      {tab_a, _} = open_page(ctx)
      tab_a |> element("#design-squad-edit") |> render_click()

      {:ok, _} =
        AgentDesigns.put_squad(ctx.alice_scope, design.id, version(design.id), %{
          "description" => "另一个标签页的描述"
        })

      save_squad(tab_a, %{"leader" => "web-lead"})
      assert open?(tab_a, "squad-panel")
      assert in_portal?(tab_a, "squad-panel", "#squad-form-notice", "草稿刚被更新")
      assert in_portal?(tab_a, "squad-panel", "#squad-form-description", "另一个标签页的描述")

      assert portal_attr(tab_a, "squad-panel", "#squad-form-leader option[selected]", "value") ==
               "web-lead"

      save_squad(tab_a, %{"leader" => "web-lead"})
      refute open?(tab_a, "squad-panel")
      squad = design!(design.id).draft["squad"]
      assert squad["leader"] == "web-lead"
      assert squad["description"] == "另一个标签页的描述"
    end

    test "移除被引用的 Agent", ctx do
      design =
        squad_drafted(ctx, [%{"name" => "web-lead"}, %{"name" => "qa"}, %{"name" => "docs"}], %{
          "name" => "web-team",
          "leader" => "web-lead",
          "members" => [%{"name" => "qa", "role_note" => ""}]
        })

      {view, _} = open_page(ctx)
      assert has_element?(view, "#draft-agent-1[data-name=qa]")
      assert has_element?(view, "#draft-agent-1-remove[aria-disabled=true]")
      assert has_element?(view, "#draft-agent-1-remove-reason", "先在小队里移除 qa")
      assert has_element?(view, "#draft-agent-0-remove-reason", "先在小队里移除 web-lead")
      refute has_element?(view, "#draft-agent-2-remove[aria-disabled=true]")
      refute has_element?(view, "#draft-agent-1-edit[aria-disabled=true]")

      html = render_click(view, "ask_remove", %{"name" => "qa"})
      assert html =~ "先在小队里移除 qa"
      refute open?(view, "design-remove")

      # The domain still refuses (another tab put qa in the squad meanwhile).
      html = render_click(view, "remove", %{"name" => "qa"})
      assert html =~ "先在小队里移除 qa"
      assert entry(design.id, "qa")
    end

    test "轮进行中", ctx do
      design =
        squad_drafted(ctx, [%{"name" => "web-lead"}], %{
          "name" => "web-team",
          "leader" => "web-lead"
        })

      {view, _} = open_page(ctx)
      view |> element("#design-squad-edit") |> render_click()
      {:ok, _} = AgentDesigns.send(ctx.alice_scope, design.id, "继续")

      assert has_element?(view, "#design-squad-edit[aria-disabled=true]")
      assert has_element?(view, "#design-squad-edit-reason", "等 helper 回复完再修改")

      assert in_portal?(
               view,
               "squad-panel",
               "#squad-form-locked-notice",
               "helper 正在回复，回复结束后才能保存"
             )

      assert portal_attr(view, "squad-panel", "#squad-form-submit", "disabled") != nil
      save_squad(view, %{"name" => "other"})
      assert design!(design.id).draft["squad"]["name"] == "web-team"
    end
  end
end
