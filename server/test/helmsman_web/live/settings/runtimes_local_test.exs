defmodule HelmsmanWeb.SettingsLive.RuntimesLocalTest do
  @moduledoc """
  Spec web-local-repositories 运行时页的本地仓库 and the runtimes page part of
  本地仓库界面的实时刷新 (add-local-repositories-ui D4, D11).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.LiveHelpers

  alias Helmsman.{Events, LocalRepositories, Projects, Tx}

  @path "/home/alice/code/app"

  setup %{conn: conn} do
    olga = user_fixture(%{display_name: "olga"})
    ws = workspace_fixture(olga, %{name: "Acme"})
    alice = user_fixture(%{display_name: "alice"})
    adam = user_fixture(%{display_name: "adam"})
    bob = user_fixture(%{display_name: "bob"})
    member_fixture(ws, alice, :member)
    member_fixture(ws, adam, :admin)
    member_fixture(ws, bob, :member)

    {mbp, _} = daemon_fixture(alice, %{name: "alice-mbp", workspace_ids: [ws.id]})
    runtime_fixture(ws, mbp)
    {bob_box, _} = daemon_fixture(bob, %{name: "bob-box", workspace_ids: [ws.id]})
    runtime_fixture(ws, bob_box)

    app = local_repository_fixture(ws, mbp, %{name: "app", path: @path})
    owner_scope = workspace_scope_fixture(olga, ws)
    bos = project_fixture(owner_scope, %{key: "BOS"})
    bind_local(bos, app)
    old = project_fixture(owner_scope, %{key: "OLD"})
    bind_local(old, app)
    {:ok, _} = Projects.archive(owner_scope, "OLD")

    %{
      conn: conn,
      ws: ws,
      users: %{alice: alice, adam: adam, bob: bob},
      mbp: mbp,
      app: app,
      owner_scope: owner_scope,
      path: "/w/#{ws.slug}/settings/runtimes"
    }
  end

  defp open(ctx, who, path \\ nil),
    do: live(log_in_user(ctx.conn, ctx.users[who]), path || ctx.path)

  defp row(app), do: "#local-repository-#{app.id}"

  test "the machine's owner sees their repository", ctx do
    {:ok, view, _html} = open(ctx, :alice)
    row = row(ctx.app)

    assert has_element?(view, "#local-repositories-section h2", "本地仓库")
    assert has_element?(view, "#local-repositories-section", "helmsman repos")
    assert has_element?(view, "#{row} [data-name]", "app")
    assert has_element?(view, "#{row} [data-machine]", "alice-mbp")
    assert has_element?(view, "#{row} [data-path]", @path)
    assert has_element?(view, "#{row} [data-default-branch]", "main")
    assert has_element?(view, ~s(#{row} [data-status="online"]), "可用")

    assert has_element?(
             view,
             ~s(#{row} a[data-project="BOS"][href="/w/#{ctx.ws.slug}/p/BOS"][data-archived="false"])
           )

    assert has_element?(view, ~s(#{row} a[data-project="OLD"][data-archived="true"]))
    refute has_element?(view, "#{row} [data-owner]")
    refute has_element?(view, "#local-repositories-section button", "删除")
  end

  test "an unavailable repository with the translated reason", ctx do
    set(ctx.app, status: "unavailable", unavailable_reason: "not configured on the machine")
    {:ok, view, _html} = open(ctx, :alice)

    assert has_element?(view, ~s(#{row(ctx.app)} [data-status="unavailable"]), "不可用")
    assert has_element?(view, "#{row(ctx.app)} [data-reason]", "机器上已不再配置")
  end

  test "the daemon's own reason is shown as is", ctx do
    web =
      local_repository_fixture(ctx.ws, ctx.mbp, %{
        name: "web",
        path: "/home/alice/code/web",
        status: "unavailable",
        unavailable_reason: "not a git repository"
      })

    {:ok, view, _html} = open(ctx, :alice)

    assert has_element?(view, ~s(#{row(web)} [data-status="unavailable"]), "不可用")

    assert has_element?(
             view,
             ~s(#{row(web)} [data-reason] span[lang="en"]),
             "not a git repository"
           )

    assert has_element?(view, "#{row(web)} [data-reason]", "机器报告：")
    assert has_element?(view, "#{row(web)} [data-project]") == false
    assert has_element?(view, "#{row(web)}", "—")
  end

  test "an admin's all view; a member never gets the path", ctx do
    {:ok, admin, _html} = open(ctx, :adam, ctx.path <> "?all=1")
    assert has_element?(admin, "#{row(ctx.app)} [data-owner]", "alice")
    assert has_element?(admin, "#{row(ctx.app)} [data-path]", @path)

    {:ok, mine, _html} = open(ctx, :adam)
    refute has_element?(mine, row(ctx.app))

    {:ok, bob, html} = open(ctx, :bob, ctx.path <> "?all=1")
    refute has_element?(bob, row(ctx.app))
    refute html =~ @path
    refute render(bob) =~ @path
    refute inspect(:sys.get_state(bob.pid)) =~ @path
  end

  test "the empty state with the command for this workspace", ctx do
    {:ok, view, _html} = open(ctx, :bob)

    assert has_element?(view, "#local-repositories-empty", "把本机的 git 仓库登记给 Helmsman")

    assert has_element?(
             view,
             "#local-repositories-add-command-text",
             "helmsman repos add <路径> --name <名字> --workspace #{ctx.ws.slug}"
           )

    refute has_element?(view, "#local-repositories")
  end

  test "no section on the page-wide empty state", ctx do
    lone = user_fixture()
    member_fixture(ctx.ws, lone, :member)
    {:ok, view, _html} = live(log_in_user(ctx.conn, lone), ctx.path)

    assert has_element?(view, "#runtimes-empty")
    refute has_element?(view, "#local-repositories-section")
  end

  describe "live updates" do
    test "the machine going offline", ctx do
      {:ok, view, _html} = open(ctx, :alice)
      assert has_element?(view, ~s(#{row(ctx.app)} [data-status="online"]))

      assert {:ok, [_]} =
               Tx.run(fn -> {:ok, LocalRepositories.offline(ctx.mbp.id, [ctx.ws.id])} end)

      eventually(fn ->
        has_element?(view, ~s(#{row(ctx.app)} [data-status="offline"]), "机器离线")
      end)
    end

    test "a project change re-reads the project column", ctx do
      {:ok, view, _html} = open(ctx, :alice)
      {:ok, _} = Projects.unarchive(ctx.owner_scope, "OLD")
      Events.broadcast(Events.topic(:workspace, ctx.ws.id), {:projects_changed})

      eventually(fn ->
        has_element?(view, ~s(#{row(ctx.app)} a[data-project="OLD"][data-archived="false"]))
      end)
    end

    test "the tick does not re-read local repositories", ctx do
      {:ok, view, _html} = open(ctx, :alice)
      set(ctx.app, status: "offline")
      send(view.pid, :tick)
      assert has_element?(view, ~s(#{row(ctx.app)} [data-status="online"]))
    end
  end

  defp set(repo, changes) do
    repo |> Ecto.Changeset.change(changes) |> Helmsman.Repo.update!()
  end
end
