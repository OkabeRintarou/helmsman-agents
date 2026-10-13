defmodule HelmsmanWeb.SquadLiveTest do
  @moduledoc """
  Spec web-squads 小队列表页、小队详情页、停用与启用小队、小队页实时刷新
  (add-squads-autopilots-ui D2, D3, D5), against `Helmsman.Squads`.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Agents, Repo, Squads}

  setup %{conn: conn} do
    olga = user_fixture(%{display_name: "olga"})
    ws = workspace_fixture(olga, %{name: "Acme"})
    alice = user_fixture(%{display_name: "alice"})
    bob = user_fixture(%{display_name: "bob"})
    carol = user_fixture(%{display_name: "carol"})
    vic = user_fixture(%{display_name: "vic"})
    member_fixture(ws, alice, :member)
    member_fixture(ws, bob, :member)
    member_fixture(ws, carol, :admin)
    member_fixture(ws, vic, :viewer)
    alice_scope = workspace_scope_fixture(alice, ws)

    managed_agent_fixture(alice_scope, %{name: "keel/lead", access: "workspace"})

    managed_agent_fixture(alice_scope, %{
      name: "keel/fe",
      access: "workspace",
      model: "sonnet",
      effort: "high"
    })

    managed_agent_fixture(alice_scope, %{name: "keel/qa", access: "owner_only"})

    %{
      conn: conn,
      ws: ws,
      users: %{olga: olga, alice: alice, bob: bob, carol: carol, vic: vic},
      alice_scope: alice_scope,
      carol_scope: workspace_scope_fixture(carol, ws),
      bob_name: Repo.get_by!(Actor, workspace_id: ws.id, user_id: bob.id).name,
      path: "/w/#{ws.slug}/squads"
    }
  end

  defp open(ctx, who, path \\ nil),
    do: live(log_in_user(ctx.conn, ctx.users[who]), path || ctx.path)

  defp web_team(ctx, attrs \\ %{}) do
    {disabled, attrs} = Map.pop(Map.new(attrs), :disabled, false)

    {:ok, view} =
      Squads.create(
        ctx.alice_scope,
        Map.merge(
          %{
            name: "web-team",
            description: "网页小队",
            leader: "keel/lead",
            members: [
              %{name: "keel/fe", role_note: "写前端"},
              %{name: "keel/qa", role_note: "测试"},
              %{name: ctx.bob_name, role_note: "拍板产品问题"}
            ]
          },
          attrs
        )
      )

    if disabled, do: {:ok, _} = Squads.disable(ctx.alice_scope, view.name)
    view.id
  end

  defp squad!(ctx, name, attrs \\ %{}) do
    {:ok, view} =
      Squads.create(ctx.alice_scope, Map.merge(%{name: name, leader: "keel/lead"}, attrs))

    view.id
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  describe "小队列表页" do
    test "列表内容", ctx do
      id = web_team(ctx)
      ops = squad!(ctx, "ops-team")
      {:ok, _} = Squads.disable(ctx.alice_scope, "ops-team")

      {:ok, view, html} = open(ctx, :alice)

      assert html =~ "web-team"
      assert has_element?(view, "#squad-#{id} [data-leader]", "keel/lead")
      assert has_element?(view, "#squad-#{id} [data-members]", "3 个成员")
      assert has_element?(view, "#squad-#{ops} [data-disabled]", "已停用")
      refute has_element?(view, "#squad-#{id} [data-disabled]")

      assert view |> element("#squad-#{id} [data-squad-link]") |> render_click() ==
               {:error, {:live_redirect, %{kind: :push, to: "/w/#{ctx.ws.slug}/squads/web-team"}}}
    end

    test "不能触发的小队", ctx do
      id = web_team(ctx)
      {:ok, view, _html} = open(ctx, :bob)

      assert has_element?(view, "#squad-#{id} [data-unavailable]", "你无权触发")
      assert render(view) =~ "你无权触发 keel/qa"
    end

    test "viewer 看得到列表但没有新建入口", ctx do
      web_team(ctx)
      {:ok, view, html} = open(ctx, :vic)

      assert html =~ "web-team"
      refute has_element?(view, "#squads-new")
      refute has_element?(view, "#squads-design")
    end

    test "空状态", ctx do
      {:ok, view, _html} = open(ctx, :alice)

      assert has_element?(view, "#squads-empty", "把任务交给小队")
      assert has_element?(view, "#squads-empty-new")

      assert has_element?(
               view,
               ~s|#squads-empty-design[href="/w/#{ctx.ws.slug}/agent-design?kind=squad"]|
             )
    end

    test "导航项", ctx do
      {:ok, view, _html} = open(ctx, :alice)
      assert has_element?(view, ~s|a[href="#{ctx.path}"][aria-current="page"]|, "小队")
    end
  end

  describe "小队详情页" do
    test "成员与可触发提示", ctx do
      web_team(ctx)
      {:ok, view, html} = open(ctx, :alice, "#{ctx.path}/web-team")

      assert html =~ "网页小队"
      assert has_element?(view, "#squad-member-leader", "Leader")
      assert has_element?(view, "#squad-member-leader", "keel/lead")
      assert has_element?(view, "#squad-member-0[data-member='keel/fe']", "写前端")
      assert has_element?(view, "#squad-member-0 [data-config]", "Claude Code · sonnet · high")
      assert has_element?(view, "#squad-member-1[data-member='keel/qa']")
      assert has_element?(view, "#squad-member-2[data-member='#{ctx.bob_name}']", "拍板产品问题")

      # olga, alice, bob, carol are members and above; only alice may trigger keel/qa.
      assert has_element?(view, "#squad-trigger-summary", "能触发这个小队的成员 1 / 4")
      assert has_element?(view, "#squad-trigger-summary [data-restricted]", "keel/qa")
      assert has_element?(view, "#squad-you [data-can-trigger]")
      assert has_element?(view, "#squad-edit")
      assert has_element?(view, "#squad-disable")
    end

    test "无管理权限", ctx do
      web_team(ctx)
      {:ok, view, _html} = open(ctx, :bob, "#{ctx.path}/web-team")

      refute has_element?(view, "#squad-edit")
      refute has_element?(view, "#squad-disable")
      assert has_element?(view, "#squad-you [data-cannot-trigger]", "你无权触发 keel/qa")
      assert has_element?(view, "#squad-you [data-refused]", "keel/qa")
    end

    test "leader 已归档", ctx do
      web_team(ctx)
      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/lead")
      {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team")

      assert has_element?(view, "#squad-leader-archived", "leader 已归档")
      assert has_element?(view, "#squad-you [data-cannot-trigger]", "leader 已归档")
    end

    test "其他工作区的小队", ctx do
      other = workspace_fixture(ctx.users.olga)
      other_scope = workspace_scope_fixture(ctx.users.olga, other)
      managed_agent_fixture(other_scope, %{name: "beta/lead"})
      {:ok, _} = Squads.create(other_scope, %{name: "beta-team", leader: "beta/lead"})

      assert_raise HelmsmanWeb.NotFoundError, fn -> open(ctx, :alice, "#{ctx.path}/beta-team") end
    end

    test "说明超过 2 KB 时缺省折叠", ctx do
      web_team(ctx, %{instructions: String.duplicate("分工说明。", 200)})
      {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team")

      refute has_element?(view, "#squad-instructions-body")
      view |> element("#squad-instructions-toggle") |> render_click()
      assert has_element?(view, "#squad-instructions-body", "分工说明")
    end
  end

  describe "停用与启用小队" do
    test "停用", ctx do
      web_team(ctx)
      {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team")

      view |> element("#squad-disable") |> render_click()
      assert render(view) =~ "排队中的 leader 运行会被取消"
      render_click(view, "disable", %{})

      assert has_element?(view, "#squad-disabled-badge")
      assert has_element?(view, "#squad-enable")
      refute has_element?(view, "#squad-disable")
    end

    test "启用", ctx do
      web_team(ctx, %{disabled: true})
      {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team")

      html = view |> element("#squad-enable") |> render_click()
      assert html =~ "错过的工作不会补派"
      refute has_element?(view, "#squad-disabled-badge")
    end
  end

  describe "小队页实时刷新" do
    test "另一个窗口修改说明", ctx do
      web_team(ctx)
      {:ok, view, _html} = open(ctx, :bob, "#{ctx.path}/web-team")

      {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{instructions: "新的分工说明"})
      eventually(fn -> has_element?(view, "#squad-instructions", "新的分工说明") end)
    end

    test "另一个窗口新建小队", ctx do
      web_team(ctx)
      {:ok, view, _html} = open(ctx, :bob)

      id = squad!(ctx, "api-team")
      eventually(fn -> has_element?(view, "#squad-#{id}", "api-team") end)
    end

    test "改名", ctx do
      web_team(ctx)
      {:ok, view, _html} = open(ctx, :bob, "#{ctx.path}/web-team")

      {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{name: "web-crew"})
      eventually(fn -> assert_patch(view) == "#{ctx.path}/web-crew" end)
      assert page_title(view) =~ "web-crew"
    end

    test "只停用 leader（不改小队）", ctx do
      web_team(ctx)
      {:ok, show, _html} = open(ctx, :alice, "#{ctx.path}/web-team")
      {:ok, index, _html} = open(ctx, :alice)

      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/lead")

      eventually(fn -> has_element?(show, "#squad-member-leader", "已停用") end)
      eventually(fn -> has_element?(show, "#squad-you [data-cannot-trigger]", "leader 已停用") end)
      eventually(fn -> has_element?(index, "[data-leader-disabled]") end)
    end

    test "只归档 leader", ctx do
      web_team(ctx)
      {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team")

      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/lead")
      eventually(fn -> has_element?(view, "#squad-leader-archived") end)
    end

    test "停用成员", ctx do
      web_team(ctx)
      {:ok, view, _html} = open(ctx, :bob, "#{ctx.path}/web-team")
      assert has_element?(view, "#squad-you [data-cannot-trigger]")

      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/qa")

      eventually(fn -> has_element?(view, "#squad-member-1 [data-member-disabled]") end)
      eventually(fn -> has_element?(view, "#squad-you [data-can-trigger]") end)
    end
  end
end
