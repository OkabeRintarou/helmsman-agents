defmodule HelmsmanWeb.AgentDesignEditLiveTest do
  @moduledoc """
  add-edit-design-conversations 2.1–2.3, spec web-agent-design 「修改对话的入口与页面」
  「修改草稿的对比」「确认修改的界面」 (D14): the entries on the agent and squad pages,
  the page's states, the comparison, reverting, the confirmation and the secrets.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AgentDesignsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{AgentDesigns, Agents, Repo, Squads}
  alias HelmsmanWeb.AgentDesignHelpers, as: H

  @secret "ENV-SENTINEL-7f3a"

  setup do
    ctx = edit_fixture()
    {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{env: %{"API_TOKEN" => @secret}})
    ctx
  end

  defp edit_path(ctx, target),
    do: HelmsmanWeb.Url.agent_design_edit_path(ctx.workspace.slug, target)

  defp open(ctx, target, user \\ nil) do
    conn = log_in_user(build_conn(), user || ctx.alice)
    {:ok, view, html} = live(conn, edit_path(ctx, target))
    {view, html}
  end

  defp start_edit(ctx, scope, target) do
    %{id: id} = start_edit!(scope, target)
    id
  end

  defp settle(id), do: H.reply!(id, "ok")

  defp save(view, params), do: render_submit(view, "agent_form_submit", %{"agent" => params})

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

  describe "修改对话的入口与页面" do
    test "从 Agent 页进入: the entry, then the start area", ctx do
      conn = log_in_user(build_conn(), ctx.alice)
      {:ok, show, _} = live(conn, HelmsmanWeb.Url.agent_path(ctx.workspace.slug, "fe-dev"))
      assert has_element?(show, "#agent-design-edit", "用对话修改")

      {:ok, view, html} =
        show |> element("#agent-design-edit") |> render_click() |> follow_redirect(conn)

      assert html =~ "用对话修改 fe-dev"
      assert has_element?(view, "#design-start")
      assert has_element?(view, "#design-edit-baseline", "以 fe-dev 当前的配置为起点")
      assert has_element?(view, "#design-visibility")
    end

    test "小队页的入口", ctx do
      conn = log_in_user(build_conn(), ctx.alice)
      {:ok, show, _} = live(conn, HelmsmanWeb.Url.squad_path(ctx.workspace.slug, "web-team"))
      assert has_element?(show, "#squad-design-edit", "用对话修改")

      conn = log_in_user(build_conn(), ctx.bob)
      {:ok, show, _} = live(conn, HelmsmanWeb.Url.squad_path(ctx.workspace.slug, "web-team"))
      refute has_element?(show, "#squad-design-edit")
    end

    test "member 看别人的 Agent: no entry, the page explains", ctx do
      conn = log_in_user(build_conn(), ctx.bob)
      {:ok, show, _} = live(conn, HelmsmanWeb.Url.agent_path(ctx.workspace.slug, "fe-dev"))
      refute has_element?(show, "#agent-design-edit")

      {view, _} = open(ctx, "fe-dev", ctx.bob)
      assert has_element?(view, "#design-edit-blocked[data-reason=forbidden]")
      refute has_element?(view, "#design-start")
    end

    test "viewer, archived, external or missing targets: empty states", ctx do
      {view, _} = open(ctx, "fe-dev", ctx.dan)
      assert has_element?(view, "#design-forbidden")
      refute has_element?(view, "#design-start")

      Helmsman.AgentsFixtures.managed_agent_fixture(ctx.alice_scope, %{
        name: "old-bot",
        runtime_id: ctx.runtime.id
      })

      {:ok, _} = Agents.archive(ctx.alice_scope, "old-bot")

      Repo.insert!(%Actor{
        workspace_id: ctx.workspace.id,
        kind: :agent,
        name: "outside",
        owner_id: ctx.alice.id
      })

      for target <- ["old-bot", "outside", "nobody"] do
        {view, _} = open(ctx, target)
        assert has_element?(view, "#design-edit-blocked[data-reason=not_found]")
        refute has_element?(view, "#design-start")
      end
    end

    test "开始修改对话", ctx do
      {view, _} = open(ctx, "fe-dev")

      view
      |> form("#design-start-form", %{"message" => "改用 opus", "helper" => "helper"})
      |> render_submit()

      assert has_element?(view, "#design-messages [data-role=user]", "改用 opus")
      assert has_element?(view, "#edit-target[data-name=fe-dev]")
      assert has_element?(view, "#design-change-count", "0 项修改")
      assert has_element?(view, "#design-confirm-open-reason", "等 helper 回复完再确认")

      {:ok, %{id: id}} = AgentDesigns.current(ctx.alice_scope, :edit)
      settle(id)
      assert has_element?(view, "#design-confirm-open-reason", "草稿与当前配置相同，没有修改")
    end

    test "已在修改另一个目标", ctx do
      start_edit(ctx, ctx.alice_scope, "fe-dev")
      {view, _} = open(ctx, "web-team")

      assert has_element?(view, "#design-edit-other", "你正在修改 fe-dev，确认或放弃后才能修改 web-team")
      assert has_element?(view, "#edit-target[data-name=fe-dev]")
      refute has_element?(view, "#design-start")
    end

    test "the same target renamed: the conversation, by its current name", ctx do
      start_edit(ctx, ctx.alice_scope, "fe-dev")

      Repo.update_all(from(a in Actor, where: a.id == ^ctx.fe_dev.id), set: [name: "ui-dev"])

      {view, html} = open(ctx, "ui-dev")
      refute has_element?(view, "#design-edit-other")
      assert html =~ "用对话修改 ui-dev"

      {view, _} = open(ctx, "fe-dev")
      refute has_element?(view, "#design-edit-other")
      assert has_element?(view, "#edit-target")
    end
  end

  describe "修改草稿的对比" do
    test "AI 改了模型与指令: marked live, a line diff, 2 项修改", ctx do
      id = start_edit(ctx, ctx.alice_scope, "fe-dev")
      {view, _} = open(ctx, "fe-dev")

      H.propose!(id, %{
        "name" => "fe-dev",
        "model" => "opus",
        "instructions" => "You build the web UI.\nUse Tailwind.\nWrite Storybook stories."
      })

      assert has_element?(view, "#edit-field-model[data-changed=true] [data-before]", "sonnet")
      assert has_element?(view, "#edit-field-model [data-now]", "opus")
      assert has_element?(view, "#edit-diff-instructions [data-added='1']")

      assert has_element?(
               view,
               "#edit-diff-instructions [data-op=ins]",
               "Write Storybook stories."
             )

      assert has_element?(view, "#design-change-count", "2 项修改")
      assert has_element?(view, "#design-tab-draft", "草稿（2 项修改）")
      refute has_element?(view, "#edit-field-effort[data-changed]")
    end

    test "恢复一个字段 in the panel", ctx do
      id = start_edit(ctx, ctx.alice_scope, "fe-dev")
      H.propose!(id, %{"name" => "fe-dev", "model" => "opus", "effort" => "low"})
      settle(id)
      {view, _} = open(ctx, "fe-dev")

      view |> element("#edit-target-edit") |> render_click()
      assert in_portal?(view, "agent-panel", "#agent-form-reverts", "模型")
      assert portal_attr(view, "agent-panel", "#agent-name", "disabled") != nil

      render_click(view, "agent_form_revert", %{"field" => "model"})
      refute in_portal?(view, "agent-panel", "#agent-form-revert-model")
      save(view, %{})

      assert has_element?(view, "#edit-field-model [data-now]", "sonnet")
      refute has_element?(view, "#edit-field-model[data-changed]")
      assert has_element?(view, "#design-change-count", "1 项修改")
      assert [%{"agent" => "fe-dev", "fields" => ["model"]}] = design!(id).pending_edits
    end

    test "恢复 on the card", ctx do
      id = start_edit(ctx, ctx.alice_scope, "fe-dev")
      H.propose!(id, %{"name" => "fe-dev", "model" => "opus"})
      settle(id)
      {view, _} = open(ctx, "fe-dev")

      view |> element("#edit-revert-model") |> render_click()
      assert has_element?(view, "#design-change-count", "0 项修改")
    end

    test "an admin's conversation: read-only fields locked; the panel only has the others",
         ctx do
      id = start_edit(ctx, ctx.carol_scope, "fe-dev")
      settle(id)
      {view, _} = open(ctx, "fe-dev", ctx.carol)

      assert has_element?(
               view,
               "#edit-field-instructions[data-readonly=true] [data-lock]",
               "只有所属用户能改"
             )

      refute has_element?(view, "#edit-field-description[data-readonly]")

      view |> element("#edit-target-edit") |> render_click()
      assert in_portal?(view, "agent-panel", "#agent-form-basic")
    end

    test "conflicts are shown after the baseline changed", ctx do
      id = start_edit(ctx, ctx.alice_scope, "fe-dev")
      H.propose!(id, %{"name" => "fe-dev", "effort" => "medium"})
      settle(id)
      {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{effort: "low"})
      {view, _} = open(ctx, "fe-dev")

      view |> element("#design-confirm-open") |> render_click()
      confirm_now(view)

      assert has_element?(view, "#design-baseline-changed", "fe-dev 在对话期间被修改（推理强度）")
      assert has_element?(view, "#edit-field-effort[data-conflict=true]")

      assert has_element?(
               view,
               "#edit-field-effort [data-conflict-note]",
               "对话期间已被改为 low，草稿保留 medium"
             )

      assert profile_of(ctx).effort == "low"
    end

    test "squad_edit: the members' changes and the new agent", ctx do
      id = start_edit(ctx, ctx.alice_scope, "web-team")

      H.propose!(id, %{
        "name" => "qa",
        "provider" => "claude",
        "runtime_id" => ctx.runtime.id,
        "instructions" => "You test."
      })

      members =
        design!(id).draft["squad"]["members"]
        |> Enum.reject(&(&1["name"] == ctx.bob_name))
        |> Kernel.++([%{"name" => "qa", "role_note" => "测试"}])

      H.propose_squad!(id, %{"members" => members})
      {view, _} = open(ctx, "web-team")

      assert has_element?(view, "#edit-field-members [data-member=qa] [data-mark=added]")

      assert has_element?(
               view,
               "#edit-field-members [data-member='#{ctx.bob_name}'] [data-mark=removed]"
             )

      assert has_element?(view, "#design-new-agents [data-name=qa]")
      assert has_element?(view, "#design-confirm-open", "应用 1 项修改并创建 1 个 Agent")
    end
  end

  describe "code review 3" do
    test "a members target keeps its access through a full form (P2-1)", ctx do
      {:ok, _} =
        Agents.update(ctx.alice_scope, "fe-dev", %{
          access: "members",
          access_member_ids: [ctx.bob.id]
        })

      id = start_edit(ctx, ctx.alice_scope, "fe-dev")
      settle(id)
      {view, _} = open(ctx, "fe-dev")
      view |> element("#edit-target-edit") |> render_click()

      assert in_portal?(view, "agent-panel", "option[value=members][selected]", "保持指定成员")

      # The browser submits every field, the access as selected.
      save(view, %{"description" => "Web UI", "access" => "members", "model" => "sonnet"})
      assert hd(design!(id).draft["agents"])["access"] == "members"

      view |> element("#design-confirm-open") |> render_click()
      confirm_now(view)
      assert %{access: "members", access_member_ids: [bob_id]} = profile_of(ctx)
      assert bob_id == ctx.bob.id
      assert profile_of(ctx).description == "Web UI"
    end

    test "after a rebaseline the open panel reverts to the new baseline (P2-2)", ctx do
      id = start_edit(ctx, ctx.alice_scope, "fe-dev")
      H.propose!(id, %{"name" => "fe-dev", "effort" => "medium"})
      settle(id)
      {view, _} = open(ctx, "fe-dev")
      view |> element("#edit-target-edit") |> render_click()

      {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{effort: "low"})
      render_click(view, "dismiss_confirm", %{})
      render_click(view, "ask_confirm", %{})
      confirm_now(view)
      assert has_element?(view, "#design-baseline-changed")

      render_click(view, "agent_form_revert", %{"field" => "effort"})
      save(view, %{})
      # A stale save (the panel opened before the rebaseline) merges, then saves.
      if open?(view, "agent-panel"), do: save(view, %{})

      assert hd(design!(id).draft["agents"])["effort"] == "low"
      refute has_element?(view, "#edit-field-effort[data-changed]")
    end

    test "the squad panel reverts to the new baseline too", ctx do
      id = start_edit(ctx, ctx.alice_scope, "web-team")
      H.propose_squad!(id, %{"instructions" => "Ship it."})
      settle(id)
      {view, _} = open(ctx, "web-team")
      view |> element("#edit-squad-edit") |> render_click()

      {:ok, _} = Squads.update(ctx.carol_scope, "web-team", %{instructions: "New rules."})
      render_click(view, "ask_confirm", %{})
      confirm_now(view)
      assert has_element?(view, "#design-baseline-changed")

      # The draft followed the new baseline (it had not changed the instructions
      # since the last check: no revert left); a field changed again reverts to it.
      render_click(view, "squad_form_change", %{"squad" => %{"instructions" => "Mine"}})
      render_click(view, "squad_form_revert", %{"field" => "instructions"})
      assert in_portal?(view, "squad-panel", "textarea[name='squad[instructions]']", "New rules.")
    end
  end

  describe "确认修改的界面" do
    test "应用修改: to the agent's page with the count", ctx do
      id = start_edit(ctx, ctx.alice_scope, "fe-dev")
      H.propose!(id, %{"name" => "fe-dev", "model" => "opus", "description" => "Web UI"})
      settle(id)
      {view, _} = open(ctx, "fe-dev")

      assert has_element?(view, "#design-confirm-open", "应用 2 项修改")
      view |> element("#design-confirm-open") |> render_click()

      assert in_portal?(
               view,
               "design-confirm",
               "#design-confirm-list [data-field=model]",
               "sonnet → opus"
             )

      assert {:error, {:live_redirect, %{to: to}}} = result = confirm_now(view)
      assert to == HelmsmanWeb.Url.agent_path(ctx.workspace.slug, "fe-dev")
      {:ok, _show, html} = follow_redirect(result, log_in_user(build_conn(), ctx.alice))
      assert html =~ "已更新 fe-dev（2 项）"
      assert profile_of(ctx).model == "opus"
    end

    test "the risky changes stand out in the dialog", ctx do
      id = start_edit(ctx, ctx.alice_scope, "fe-dev")

      H.propose!(id, %{
        "name" => "fe-dev",
        "access" => "workspace",
        "capabilities" => ["create_tasks"],
        "runtime_id" => nil
      })

      settle(id)
      {view, _} = open(ctx, "fe-dev")
      view |> element("#design-confirm-open") |> render_click()

      for field <- ~w(access capabilities runtime_id) do
        assert in_portal?(view, "design-confirm", "[data-field=#{field}][data-risky=true]")
      end

      assert in_portal?(view, "design-confirm", "[data-field=runtime_id]", "排队中的运行会被取消")
    end

    test "unavailable while the helper replies", ctx do
      id = start_edit(ctx, ctx.alice_scope, "fe-dev")
      H.propose!(id, %{"name" => "fe-dev", "model" => "opus"})
      {view, _} = open(ctx, "fe-dev")
      assert has_element?(view, "#design-confirm-open-reason", "等 helper 回复完再确认")
    end

    test "a draft change closes the dialog", ctx do
      id = start_edit(ctx, ctx.alice_scope, "fe-dev")
      H.propose!(id, %{"name" => "fe-dev", "model" => "opus"})
      settle(id)
      {view, _} = open(ctx, "fe-dev")
      view |> element("#design-confirm-open") |> render_click()
      assert open?(view, "design-confirm")

      {:ok, _} =
        AgentDesigns.put_agent(ctx.alice_scope, id, design!(id).draft_version, %{
          "name" => "fe-dev",
          "effort" => "low"
        })

      refute open?(view, "design-confirm")
      assert render(view) =~ "草稿刚被更新，请检查后再确认"
    end

    test "a squad confirm creates its new agent and goes to the squad", ctx do
      id = start_edit(ctx, ctx.alice_scope, "web-team")

      H.propose!(id, %{
        "name" => "qa",
        "provider" => "claude",
        "runtime_id" => ctx.runtime.id,
        "instructions" => "You test."
      })

      H.propose_squad!(id, %{
        "members" => design!(id).draft["squad"]["members"] ++ [%{"name" => "qa"}]
      })

      settle(id)
      {view, _} = open(ctx, "web-team")
      view |> element("#design-confirm-open") |> render_click()
      assert in_portal?(view, "design-confirm", "[data-name=qa]")

      assert {:error, {:live_redirect, %{to: to}}} = confirm_now(view)
      assert to == HelmsmanWeb.Url.squad_path(ctx.workspace.slug, "web-team")
      {:ok, squad} = Squads.get(ctx.alice_scope, "web-team")
      assert "qa" in Enum.map(squad.members, & &1.name)
    end
  end

  test "no secret on the page or in its state", ctx do
    key = "sk-KEY-SENTINEL-91c2"

    account =
      Helmsman.ProviderAccountsFixtures.provider_account_fixture(ctx.alice, %{
        cli: "claude",
        api_key: key
      })

    {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{provider_account_id: account.id})
    {:ok, _} = Agents.update(ctx.alice_scope, "helper", %{env: %{"HELPER_TOKEN" => @secret}})
    id = start_edit(ctx, ctx.alice_scope, "fe-dev")
    H.propose!(id, %{"name" => "fe-dev", "model" => "opus"})
    settle(id)
    {view, html} = open(ctx, "fe-dev")
    view |> element("#edit-target-edit") |> render_click()
    view |> element("#design-confirm-open") |> render_click()

    for sentinel <- [@secret, key] do
      refute html =~ sentinel
      refute render(view) =~ sentinel
      refute H.state(view) =~ sentinel
    end
  end

  defp profile_of(ctx), do: Helmsman.RunsFixtures.profile(ctx.fe_dev)
end
