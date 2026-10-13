defmodule HelmsmanWeb.SettingsLive.GitHubTest do
  @moduledoc """
  Spec web-github GitHub 设置页 / 连接回调回到设置页 / 断开 GitHub / 仓库列表 /
  GitHub 设置页实时刷新 (add-github-ui tasks 1.2–1.6).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Events, GitHub, Projects, Repo}
  alias Helmsman.GitHub.Installation
  alias Helmsman.Workspaces.Membership

  @secrets ["test-webhook-secret", "test-client-secret", "PRIVATE KEY"]

  setup %{conn: conn} do
    # The first user registered in a test is an instance administrator.
    instance_admin = user_fixture()
    owner = user_fixture()
    ws = workspace_fixture(owner, %{name: "Acme"})
    users = %{owner: owner, instance_admin: instance_admin}

    users =
      for role <- [:admin, :member, :viewer], into: users do
        user = user_fixture()
        member_fixture(ws, user, role)
        {role, user}
      end

    member_fixture(ws, instance_admin, :admin)

    %{conn: conn, ws: ws, users: users, path: "/w/#{ws.slug}/settings/github"}
  end

  defp open(ctx, role), do: live(log_in_user(ctx.conn, ctx.users[role]), ctx.path)

  defp scope(ctx, role), do: workspace_scope_fixture(ctx.users[role], ctx.ws)

  defp repo(installation, name, attrs \\ %{}),
    do: repository_fixture(installation, Map.merge(%{owner: "acme", name: name}, attrs))

  defp row(repository), do: "#repository-#{repository.id}"

  describe "connection card" do
    test "a viewer sees the connected organization without 断开 or secrets", ctx do
      installation_fixture(ctx.ws, account_login: "acme-inc", account_type: "Organization")

      {:ok, view, html} = open(ctx, :viewer)

      assert has_element?(view, "header h1", "GitHub")
      assert page_title(view) == "GitHub · Acme"
      assert has_element?(view, ~s(#github-connection[data-state="connected"]))
      assert has_element?(view, "#github-account", "acme-inc")
      assert has_element?(view, "#github-account-type", "组织")
      assert has_element?(view, "#github-badge", "已连接")
      refute has_element?(view, "#github-disconnect")
      for secret <- @secrets, do: refute(html =~ secret)
    end

    test "the card links to the installation's repository access on GitHub", ctx do
      installation =
        installation_fixture(ctx.ws, account_login: "acme-inc", account_type: "Organization")

      {:ok, view, _html} = open(ctx, :admin)

      assert has_element?(
               view,
               ~s(a#github-manage-access[href="https://github.com/organizations/acme-inc/settings/installations/#{installation.installation_id}"][target="_blank"][rel="noopener noreferrer"]),
               "在 GitHub 上管理仓库访问"
             )

      {:ok, _} = GitHub.disconnect_installation(scope(ctx, :admin))
      {:ok, view, _html} = open(ctx, :admin)
      refute has_element?(view, "#github-manage-access")
    end

    test "an admin of an unconnected workspace gets the connect link", ctx do
      {:ok, view, _html} = open(ctx, :admin)

      assert has_element?(view, ~s(#github-connection[data-state="not_connected"]))

      assert has_element?(
               view,
               ~s(a#github-connect[href="/w/#{ctx.ws.slug}/settings/github/connect"]),
               "连接 GitHub"
             )
    end

    test "a member sees who may connect instead of the link", ctx do
      {:ok, view, _html} = open(ctx, :member)

      refute has_element?(view, "#github-repositories")

      refute has_element?(view, "#github-connect")
      assert has_element?(view, "#github-ask-admin", "请工作区的所有者或管理员连接")
    end

    test "a personal account, suspended", ctx do
      installation_fixture(ctx.ws,
        account_login: "olivia",
        account_type: "User",
        suspended_at: DateTime.utc_now(:second)
      )

      {:ok, view, _html} = open(ctx, :admin)

      assert has_element?(view, ~s(#github-connection[data-state="suspended"]))
      assert has_element?(view, "#github-account-type", "个人账号")
      assert has_element?(view, "#github-badge", "已在 GitHub 上暂停")
      assert has_element?(view, "#github-suspended-note", "暂停期间仓库不可用")
      assert has_element?(view, "#github-disconnect")
    end

    test "a disconnected installation offers 重新连接 to admins", ctx do
      installation_fixture(ctx.ws, disconnected_at: DateTime.utc_now(:second))

      {:ok, view, _html} = open(ctx, :admin)

      assert has_element?(view, "#github-badge", "已断开")
      assert has_element?(view, "#github-disconnected-note", "项目的仓库绑定已保留")

      assert has_element?(
               view,
               ~s(a#github-reconnect[href="/w/#{ctx.ws.slug}/settings/github/connect"])
             )

      refute has_element?(view, "#github-disconnect")
    end
  end

  describe "installation callback" do
    defp stub_installation(id) do
      stub_github(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/login/oauth/access_token"} ->
            Req.Test.json(conn, %{"access_token" => "gho_user"})

          {"GET", "/user/installations"} ->
            Req.Test.json(conn, %{"installations" => [%{"id" => id}]})

          {"GET", "/app/installations/" <> _} ->
            Req.Test.json(
              conn,
              github_installation(id, %{
                "account" => %{"login" => "acme-inc", "type" => "Organization"}
              })
            )

          _ ->
            not_found(conn)
        end
      end)
    end

    defp setup_callback(ctx, id) do
      state = HelmsmanWeb.GitHubState.sign_install(ctx.ws.id, ctx.users.admin.id)
      conn = log_in_user(ctx.conn, ctx.users.admin)

      get(conn, "/github/setup", %{
        installation_id: Integer.to_string(id),
        setup_action: "install",
        code: "oauth-code",
        state: state
      })
    end

    test "a successful connection returns to the settings page", ctx do
      id = unique_github_id()
      stub_installation(id)

      conn = setup_callback(ctx, id)
      assert redirected_to(conn) == ctx.path
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "已连接 GitHub，正在同步仓库"

      {:ok, view, html} = live(recycle(conn), ctx.path)
      assert html =~ "已连接 GitHub，正在同步仓库"
      assert has_element?(view, ~s(#github-connection[data-state="connected"]))
      assert has_element?(view, "#github-account", "acme-inc")
    end

    test "an installation of another workspace is refused", ctx do
      id = unique_github_id()
      other = workspace_fixture(user_fixture())
      installation_fixture(other, installation_id: id)
      stub_installation(id)

      conn = setup_callback(ctx, id)
      assert redirected_to(conn) == ctx.path

      {:ok, view, html} = live(recycle(conn), ctx.path)
      assert html =~ "该 GitHub 安装已被其他工作区使用"
      assert has_element?(view, ~s(#github-connection[data-state="not_connected"]))
    end
  end

  describe "disconnect" do
    setup ctx do
      installation = installation_fixture(ctx.ws, account_login: "acme-inc")
      web = repo(installation, "web")
      api = repo(installation, "api")
      project_fixture(scope(ctx, :owner), key: "BOS", name: "Bosun")

      {:ok, _} =
        Projects.update_github_settings(scope(ctx, :owner), "BOS", %{repository_id: web.id})

      %{installation: installation, web: web, api: api}
    end

    test "confirming disconnects; bound repositories stay listed as unavailable", ctx do
      {:ok, view, _html} = open(ctx, :admin)

      view |> element("#github-disconnect") |> render_click()
      assert open?(view, "disconnect-github-dialog")

      assert in_portal?(
               view,
               "disconnect-github-dialog",
               "#disconnect-github-dialog",
               "不会在 GitHub 上卸载 App"
             )

      assert render_click(view, "disconnect", %{}) =~ "已断开 GitHub"
      refute open?(view, "disconnect-github-dialog")

      assert has_element?(view, "#github-badge", "已断开")
      assert has_element?(view, "#github-reconnect")
      assert has_element?(view, "#{row(ctx.web)} [data-unavailable]", "不可用")
      assert has_element?(view, ~s(#{row(ctx.web)} [data-project="BOS"]))
      refute has_element?(view, "[data-available]")
      assert Repo.get!(Installation, ctx.installation.id).disconnected_at
    end

    test "cancelling changes nothing", ctx do
      {:ok, view, _html} = open(ctx, :admin)

      view |> element("#github-disconnect") |> render_click()
      render_click(view, "dismiss", %{})

      refute open?(view, "disconnect-github-dialog")
      assert has_element?(view, "#github-badge", "已连接")
      refute Repo.get!(Installation, ctx.installation.id).disconnected_at
    end

    test "an admin demoted while the dialog is open is refused", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      view |> element("#github-disconnect") |> render_click()

      Repo.get_by!(Membership, workspace_id: ctx.ws.id, user_id: ctx.users.admin.id)
      |> Ecto.Changeset.change(role: :member)
      |> Repo.update!()

      assert render_click(view, "disconnect", %{}) =~
               "只有工作区的所有者或管理员可以断开 GitHub"

      assert has_element?(view, "#github-badge", "已连接")
      refute Repo.get!(Installation, ctx.installation.id).disconnected_at
    end

    test "events from a member are refused", ctx do
      {:ok, view, _html} = open(ctx, :member)

      assert render_click(view, "ask_disconnect", %{}) =~ "只有工作区的所有者或管理员"
      render_click(view, "disconnect", %{})
      refute Repo.get!(Installation, ctx.installation.id).disconnected_at
    end
  end

  describe "repository table" do
    setup ctx do
      %{installation: installation_fixture(ctx.ws)}
    end

    test "rows link to GitHub and list the bound projects, archived ones dimmed", ctx do
      web = repo(ctx.installation, "web", %{private: true, default_branch: "trunk"})
      owner = scope(ctx, :owner)
      project_fixture(owner, key: "BOS", name: "Bosun")
      project_fixture(owner, key: "OLD", name: "Old")
      {:ok, _} = Projects.update_github_settings(owner, "BOS", %{repository_id: web.id})
      {:ok, _} = Projects.update_github_settings(owner, "OLD", %{repository_id: web.id})
      {:ok, _} = Projects.archive(owner, "OLD")

      {:ok, view, _html} = open(ctx, :viewer)

      assert has_element?(
               view,
               ~s(#{row(web)} a[data-name][href="https://github.com/acme/web"][target="_blank"][rel="noopener noreferrer"]),
               "acme/web"
             )

      assert has_element?(view, "#{row(web)} [data-private]", "私有")
      assert has_element?(view, "#{row(web)} [data-default-branch]", "trunk")
      assert has_element?(view, "#{row(web)} [data-available]", "可用")

      assert has_element?(
               view,
               ~s(#{row(web)} a[data-project="BOS"][href="/w/#{ctx.ws.slug}/p/BOS"])
             )

      refute has_element?(view, ~s(#{row(web)} a[data-project="BOS"][data-archived]))

      assert has_element?(
               view,
               ~s(#{row(web)} a[data-project="OLD"][data-archived].text-fg-subtle)
             )
    end

    test "unavailable repositories: archived, or removed but still bound", ctx do
      archived = repo(ctx.installation, "old", %{archived: true})
      api = repo(ctx.installation, "api")
      project_fixture(scope(ctx, :owner), key: "BOS", name: "Bosun")

      {:ok, _} =
        Projects.update_github_settings(scope(ctx, :owner), "BOS", %{repository_id: api.id})

      api
      |> Ecto.Changeset.change(removed_at: DateTime.utc_now(:second))
      |> Repo.update!()

      {:ok, view, _html} = open(ctx, :viewer)

      assert has_element?(view, "#{row(archived)} [data-unavailable]", "不可用")
      assert has_element?(view, "#{row(api)} [data-unavailable]", "不可用")
      assert has_element?(view, ~s(#{row(api)} [data-project="BOS"]))
    end

    test "a removed repository bound only by an archived project is listed, sorted", ctx do
      zed = repo(ctx.installation, "zed")
      old = repo(ctx.installation, "beta")
      owner = scope(ctx, :owner)
      project_fixture(owner, key: "OLD", name: "Old")
      {:ok, _} = Projects.update_github_settings(owner, "OLD", %{repository_id: old.id})
      {:ok, _} = Projects.archive(owner, "OLD")
      old |> Ecto.Changeset.change(removed_at: DateTime.utc_now(:second)) |> Repo.update!()

      {:ok, view, _html} = open(ctx, :viewer)

      assert has_element?(view, "#{row(old)} [data-unavailable]", "不可用")

      assert has_element?(
               view,
               ~s(#{row(old)} a[data-project="OLD"][data-archived].text-fg-subtle)
             )

      ids =
        view
        |> element("#repositories")
        |> render()
        |> then(&LazyHTML.from_fragment("<table>#{&1}</table>"))
        |> LazyHTML.query("#repositories > tr")
        |> LazyHTML.attribute("id")

      assert ids == ["repository-#{old.id}", "repository-#{zed.id}"]
    end

    test "archived repositories carry the 已归档 badge", ctx do
      old = repo(ctx.installation, "old", %{archived: true})
      web = repo(ctx.installation, "web")

      {:ok, view, _html} = open(ctx, :viewer)

      assert has_element?(view, "#{row(old)} [data-archived]", "已归档")
      refute has_element?(view, "#{row(web)} [data-archived]")
    end

    test "an installation without repositories shows the empty state", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      assert has_element?(view, "#github-repositories-empty", "安装没有授权任何仓库")
    end

    test "re-sync is for owners and admins", ctx do
      repo(ctx.installation, "web")
      {:ok, member_view, _html} = open(ctx, :member)
      refute has_element?(member_view, "#github-resync")

      {:ok, view, _html} = open(ctx, :admin)

      assert view |> element("#github-resync") |> render_click() =~ "已开始同步仓库"
    end

    test "more than 10 repositories can be filtered by name", ctx do
      repositories =
        for i <- 1..30 do
          name = if rem(i, 10) == 0, do: "web-#{i}", else: "svc-#{i}"
          repo(ctx.installation, name)
        end

      {:ok, view, _html} = open(ctx, :viewer)
      assert has_element?(view, "#github-repositories-filter")

      view |> form("#github-repositories-filter", %{"q" => "WEB"}) |> render_change()

      for r <- repositories do
        if String.starts_with?(r.name, "web"),
          do: assert(has_element?(view, row(r))),
          else: refute(has_element?(view, row(r)))
      end

      view |> form("#github-repositories-filter", %{"q" => "nothing"}) |> render_change()
      assert has_element?(view, "#github-repositories-no-match")
    end

    test "ten repositories need no filter", ctx do
      for i <- 1..10, do: repo(ctx.installation, "r#{i}")
      {:ok, view, _html} = open(ctx, :viewer)
      refute has_element?(view, "#github-repositories-filter")
    end
  end

  describe "live updates" do
    setup ctx do
      %{installation: installation_fixture(ctx.ws)}
    end

    test "a synced repository appears", ctx do
      {:ok, view, _html} = open(ctx, :viewer)

      docs = repo(ctx.installation, "docs")
      Events.broadcast(Events.topic(:workspace, ctx.ws.id), {:github_changed})

      assert has_element?(view, row(docs), "acme/docs")
    end

    test "a project bound elsewhere shows up in the row", ctx do
      web = repo(ctx.installation, "web")
      project_fixture(scope(ctx, :owner), key: "BOS", name: "Bosun")
      {:ok, view, _html} = open(ctx, :viewer)
      refute has_element?(view, ~s(#{row(web)} [data-project="BOS"]))

      {:ok, _} =
        Projects.update_github_settings(scope(ctx, :admin), "BOS", %{repository_id: web.id})

      assert has_element?(view, ~s(#{row(web)} [data-project="BOS"]))
    end

    test "a disconnect elsewhere updates the card, an open dialog stays", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      view |> element("#github-disconnect") |> render_click()

      {:ok, _} = GitHub.disconnect_installation(scope(ctx, :owner))

      assert has_element?(view, "#github-badge", "已断开")
      assert render_click(view, "disconnect", %{}) =~ "GitHub 已经断开"
    end
  end
end

defmodule HelmsmanWeb.SettingsLive.GitHubUnconfiguredTest do
  @moduledoc "Spec web-github GitHub 设置页「未配置」 (removes the App environment variables)."
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.WorkspacesFixtures

  setup %{conn: conn} do
    without_app_env()
    instance_admin = user_fixture()
    owner = user_fixture()
    ws = workspace_fixture(owner, %{name: "Acme"})
    member_fixture(ws, instance_admin, :admin)
    %{conn: conn, ws: ws, owner: owner, instance_admin: instance_admin}
  end

  test "workspace admins see 未配置 without the instance link", %{conn: conn, ws: ws} = ctx do
    {:ok, view, _html} = live(log_in_user(conn, ctx.owner), "/w/#{ws.slug}/settings/github")

    assert has_element?(view, ~s(#github-connection[data-state="not_configured"]), "GitHub 未配置")
    assert has_element?(view, "#github-connection", "实例管理员需要先创建 GitHub App")
    refute has_element?(view, "#github-connect")
    refute has_element?(view, ~s(a[href="/admin/github"]))
  end

  test "instance administrators get a link to /admin/github", %{conn: conn, ws: ws} = ctx do
    {:ok, view, _html} =
      live(log_in_user(conn, ctx.instance_admin), "/w/#{ws.slug}/settings/github")

    assert has_element?(view, ~s(a#github-admin-link[href="/admin/github"]), "前往实例管理")
  end
end
