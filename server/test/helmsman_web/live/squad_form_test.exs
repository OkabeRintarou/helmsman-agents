defmodule HelmsmanWeb.SquadFormTest do
  @moduledoc """
  Spec web-squads 新建与编辑小队 (add-squads-autopilots-ui D4), against
  `Helmsman.Squads`.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.Actors.Actor
  alias Helmsman.{Repo, Squads, Tasks}

  setup %{conn: conn} do
    olga = user_fixture(%{display_name: "olga"})
    ws = workspace_fixture(olga, %{name: "Acme"})
    alice = user_fixture(%{display_name: "alice"})
    bob = user_fixture(%{display_name: "bob"})
    carol = user_fixture(%{display_name: "carol"})
    member_fixture(ws, alice, :member)
    member_fixture(ws, bob, :member)
    member_fixture(ws, carol, :admin)
    alice_scope = workspace_scope_fixture(alice, ws)
    carol_scope = workspace_scope_fixture(carol, ws)

    for name <- ~w(keel/lead keel/lead2 keel/fe),
        do: managed_agent_fixture(alice_scope, %{name: name, access: "workspace"})

    managed_agent_fixture(alice_scope, %{name: "keel/qa", access: "owner_only"})
    managed_agent_fixture(carol_scope, %{name: "carol/lead", access: "workspace"})

    %{
      conn: conn,
      ws: ws,
      users: %{alice: alice, bob: bob, carol: carol},
      alice_scope: alice_scope,
      carol_scope: carol_scope,
      path: "/w/#{ws.slug}/squads",
      bob_name: Repo.get_by!(Actor, workspace_id: ws.id, user_id: bob.id).name
    }
  end

  defp open(ctx, who, path),
    do: live(log_in_user(ctx.conn, ctx.users[who]), path)

  defp change(view, params), do: render_change(view, "squad_form_change", %{"squad" => params})

  defp submit(view, params \\ %{}),
    do: render_submit(view, "squad_form_submit", %{"squad" => params})

  defp web_team(ctx, members \\ [%{name: "keel/fe", role_note: "写前端"}]) do
    {:ok, view} =
      Squads.create(ctx.alice_scope, %{name: "web-team", leader: "keel/lead", members: members})

    view.id
  end

  test "新建小队", ctx do
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}?panel=new-squad")

    change(view, %{"name" => "web-team", "leader" => "keel/lead"})
    change(view, %{"add" => "keel/fe"})
    change(view, %{"add" => ctx.bob_name})

    {:ok, show, html} =
      view
      |> submit(%{
        "name" => "web-team",
        "leader" => "keel/lead",
        "members" => %{"0" => %{"role_note" => "写前端"}, "1" => %{"role_note" => "拍板产品问题"}}
      })
      |> follow_redirect(log_in_user(ctx.conn, ctx.users.alice), "#{ctx.path}/web-team")

    assert html =~ "已保存 web-team"
    assert has_element?(show, "#squad-member-0[data-member='keel/fe']", "写前端")
    assert has_element?(show, "#squad-member-1[data-member='#{ctx.bob_name}']", "拍板产品问题")
  end

  test "member 不能选别人的 Agent 作为 leader；admin 可以", ctx do
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}?panel=new-squad")

    assert in_portal?(
             view,
             "squad-panel",
             ~s|#squad-form-leader option[value="carol/lead"][disabled]|,
             "只能选你自己的 Agent"
           )

    refute in_portal?(
             view,
             "squad-panel",
             ~s|#squad-form-leader option[value="keel/lead"][disabled]|
           )

    {:ok, admin, _html} = open(ctx, :carol, "#{ctx.path}?panel=new-squad")

    refute in_portal?(
             admin,
             "squad-panel",
             ~s|#squad-form-leader option[value="keel/lead"][disabled]|
           )

    refute in_portal?(
             admin,
             "squad-panel",
             ~s|#squad-form-leader option[value="carol/lead"][disabled]|
           )
  end

  test "有受限成员时提示可触发人数", ctx do
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}?panel=new-squad")
    change(view, %{"name" => "qa-team", "leader" => "keel/lead"})
    change(view, %{"add" => "keel/qa"})

    {:ok, _show, html} =
      view
      |> submit(%{"name" => "qa-team", "leader" => "keel/lead"})
      |> follow_redirect(log_in_user(ctx.conn, ctx.users.alice))

    assert html =~ "已保存 qa-team"
    assert html =~ "能触发这个小队的成员 1 / 4"
    assert html =~ "keel/qa"
  end

  test "换 leader 时列出被取消的排队运行", ctx do
    web_team(ctx)
    project_fixture(ctx.carol_scope, %{key: "BOS", name: "Bosun"})
    {:ok, task} = Tasks.create(ctx.alice_scope, "BOS", %{title: "x"})
    lead = Helmsman.RunsFixtures.agent_actor(ctx.ws, "keel/lead")
    {:ok, squad} = Squads.get(ctx.alice_scope, "web-team")
    Helmsman.RunsFixtures.run_fixture(lead, %{task_id: task.id, squad_id: squad.id})
    {:ok, view, _html} = open(ctx, :carol, "#{ctx.path}/web-team?panel=edit")

    change(view, %{"leader" => "keel/lead2"})
    html = submit(view, %{"leader" => "keel/lead2"})

    assert html =~ "已取消旧 leader 在 #{task.ident} 上排队的运行"
    assert html =~ "@web-team"
    assert has_element?(view, "#squad-member-leader[data-member='keel/lead2']")
  end

  test "调整成员顺序", ctx do
    web_team(ctx, [%{name: "keel/fe"}, %{name: ctx.bob_name}, %{name: "keel/qa"}])
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team?panel=edit")

    render_click(view, "squad_form_move", %{"index" => "2", "dir" => "up"})
    assert in_portal?(view, "squad-panel", "#squad-form-member-1[data-member='keel/qa']")

    submit(view)
    assert has_element?(view, "#squad-members #squad-member-1[data-member='keel/qa']")
    assert has_element?(view, "#squad-members #squad-member-2[data-member='#{ctx.bob_name}']")
  end

  test "名字被占用", ctx do
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}?panel=new-squad")
    change(view, %{"name" => "keel/fe", "leader" => "keel/lead"})
    html = submit(view, %{"name" => "keel/fe", "leader" => "keel/lead"})

    assert html =~ "已被占用"
    assert in_portal?(view, "squad-panel", "#squad-form-name[value='keel/fe']")
  end

  test "版本冲突保留输入，载入最新", ctx do
    web_team(ctx)
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team?panel=edit")
    change(view, %{"description" => "我的描述"})

    {:ok, _} = Squads.update(ctx.carol_scope, "web-team", %{instructions: "admin 改的"})
    submit(view, %{"description" => "我的描述"})

    assert in_portal?(view, "squad-panel", "#squad-form-stale", "这个小队刚被他人修改")
    assert in_portal?(view, "squad-panel", "#squad-form-description", "我的描述")

    render_click(view, "squad_form_reload", %{})
    refute in_portal?(view, "squad-panel", "#squad-form-stale")
    refute in_portal?(view, "squad-panel", "#squad-form-description", "我的描述")
  end

  test "满 16 个成员时不能再添加", ctx do
    members = for i <- 1..16, do: %{name: "bot#{i}"}
    alice_scope = workspace_scope_fixture(ctx.users.alice, ctx.ws)
    for %{name: n} <- members, do: managed_agent_fixture(alice_scope, %{name: n})
    web_team(ctx, members)

    {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team?panel=edit")
    assert in_portal?(view, "squad-panel", "#squad-form-add[disabled]")
    assert in_portal?(view, "squad-panel", "#squad-form-add", "最多 16 个成员")
  end

  test "把成员选为 leader 时从成员里移除并提示", ctx do
    web_team(ctx, [%{name: "keel/fe"}, %{name: "keel/lead2"}])
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team?panel=edit")

    change(view, %{"leader" => "keel/lead2"})
    assert in_portal?(view, "squad-panel", "#squad-form-leader-moved", "keel/lead2")
    refute in_portal?(view, "squad-panel", "#squad-form [data-member='keel/lead2']")
  end

  test "role_note 超过 2048 字节时错误显示在该成员行", ctx do
    web_team(ctx, [%{name: "keel/fe"}, %{name: ctx.bob_name}])
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team?panel=edit")

    long = String.duplicate("a", 2049)
    submit(view, %{"members" => %{"1" => %{"role_note" => long}}})

    assert in_portal?(
             view,
             "squad-panel",
             "#squad-form-member-1",
             "role note should be at most 2048 bytes"
           )

    refute in_portal?(view, "squad-panel", "#squad-form-member-0", "role note")
  end

  # code-review-1 P2-1: a rename elsewhere keeps the open panel, its draft and version.
  test "他人改名时编辑草稿保留，提交得到冲突，载入最新后可保存", ctx do
    web_team(ctx)
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.path}/web-team?panel=edit")
    change(view, %{"description" => "UNSAVED-DRAFT"})

    {:ok, _} = Squads.update(ctx.carol_scope, "web-team", %{name: "web-crew"})

    eventually(fn -> assert_patch(view) == "#{ctx.path}/web-crew?panel=edit" end)
    assert in_portal?(view, "squad-panel", "#squad-form-description", "UNSAVED-DRAFT")

    submit(view, %{"description" => "UNSAVED-DRAFT"})
    assert in_portal?(view, "squad-panel", "#squad-form-stale", "这个小队刚被他人修改")
    assert in_portal?(view, "squad-panel", "#squad-form-description", "UNSAVED-DRAFT")

    render_click(view, "squad_form_reload", %{})
    assert in_portal?(view, "squad-panel", "#squad-form-name[value='web-crew']")
    change(view, %{"description" => "after reload"})
    submit(view, %{"description" => "after reload"})
    assert has_element?(view, "#squad-description", "after reload")
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
