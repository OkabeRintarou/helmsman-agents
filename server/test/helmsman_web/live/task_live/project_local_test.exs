defmodule HelmsmanWeb.TaskLive.ProjectLocalTest do
  @moduledoc """
  Spec web-local-repositories 项目绑定本地仓库 / 项目显示绑定的本地仓库 and the panel part
  of 本地仓库界面的实时刷新 (add-local-repositories-ui D5, D6, D11; tasks 2.1–2.4).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import HelmsmanWeb.LiveHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Events, Projects, Repo}
  alias HelmsmanWeb.ProjectGitHubForm

  @panel "project-github"
  @path "/home/alice/code/app"

  setup %{conn: conn} do
    owner = user_fixture(%{display_name: "olga"})
    ws = workspace_fixture(owner)
    alice = user_fixture(%{display_name: "alice"})
    adam = user_fixture(%{display_name: "adam"})
    bob = user_fixture(%{display_name: "bob"})
    member_fixture(ws, alice, :member)
    member_fixture(ws, adam, :admin)
    member_fixture(ws, bob, :member)

    {mbp, _} = daemon_fixture(alice, %{name: "alice-mbp", workspace_ids: [ws.id]})
    app = local_repository_fixture(ws, mbp, %{name: "app", path: @path})

    web =
      local_repository_fixture(ws, mbp, %{
        name: "web",
        path: "/home/alice/code/web",
        default_branch: nil,
        status: "offline"
      })

    owner_scope = workspace_scope_fixture(owner, ws)
    project_fixture(owner_scope, key: "BOS", name: "Bosun")

    # Branch suggestions of a GitHub-bound project's panel.
    stub_github(fn conn ->
      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"POST", ["app", "installations", _id, "access_tokens"]} ->
          token_response(conn)

        {"GET", ["repos", _owner, _name, "branches"]} ->
          Req.Test.json(conn, [%{"name" => "main"}])
      end
    end)

    %{
      conn: conn,
      ws: ws,
      users: %{alice: alice, adam: adam, bob: bob, owner: owner},
      owner_scope: owner_scope,
      app: app,
      web: web,
      base: "/w/#{ws.slug}/p/BOS"
    }
  end

  defp open(ctx, who \\ :adam, query \\ "?panel=project-github"),
    do: live(log_in_user(ctx.conn, ctx.users[who]), ctx.base <> query)

  defp form_state(view), do: :sys.get_state(view.pid).socket.assigns.github

  defp mode(view, mode), do: render_click(view, "project_github_mode", %{"mode" => mode})

  defp select(view, repo),
    do: render_click(view, "project_github_local_repository", %{"id" => repo && repo.id})

  defp change(view, params),
    do: render_change(view, "project_github_change", %{"project_github" => params})

  defp save(view, params),
    do: render_submit(view, "project_github_save", %{"project_github" => params})

  defp project(ctx) do
    {:ok, project} = Projects.get(ctx.owner_scope, "BOS")
    project
  end

  defp bind(ctx, repo, branch \\ nil), do: bind_local(project(ctx), repo, branch)

  defp bind_github(ctx) do
    installation = installation_fixture(ctx.ws)
    repository = repository_fixture(installation, owner: "acme", name: "app")
    bind_repository(project(ctx), repository)
  end

  describe "mode and fields (2.1)" do
    test "the explanation that only that machine runs the project", ctx do
      {:ok, view, _html} = open(ctx)
      assert form_state(view).mode == :github
      assert in_portal?(view, @panel, ~s(#project-github-mode-github[aria-checked="true"]))

      mode(view, "local")
      assert in_portal?(view, @panel, ~s(#project-github-mode-local[aria-checked="true"]))
      assert in_portal?(view, @panel, "#project-github-local-base-branch[disabled]")
      refute in_portal?(view, @panel, "#project-github-local-info")

      select(view, ctx.app)

      assert in_portal?(
               view,
               @panel,
               "#project-github-local-info",
               "只有 alice-mbp（alice）上的运行时能执行这个项目的运行"
             )

      assert in_portal?(view, @panel, "#project-github-local-info [data-path]", @path)
      refute in_portal?(view, @panel, "#project-github-local-status")

      assert portal_attr(view, @panel, "#project-github-local-base-branch", "placeholder") ==
               "缺省：main"

      assert in_portal?(view, @panel, ~s(#project-github-local-branches option[value="main"]))
    end

    test "an offline repository can be chosen, with its explanation", ctx do
      {:ok, view, _html} = open(ctx)
      mode(view, "local")
      select(view, ctx.web)

      assert in_portal?(view, @panel, "#project-github-local-status", "所在机器离线")

      assert portal_attr(view, @panel, "#project-github-local-base-branch", "placeholder") ==
               "缺省：仓库当前检出的分支"
    end

    test "a project bound to a GitHub repository cannot switch to local", ctx do
      bind_github(ctx)
      {:ok, view, _html} = open(ctx)

      assert in_portal?(view, @panel, "#project-github-mode-local[disabled]")

      assert in_portal?(
               view,
               @panel,
               "#project-github-mode-locked",
               "先在当前模式下选择『不绑定』并保存，再切换"
             )

      mode(view, "local")
      assert form_state(view).mode == :github
    end

    test "the local mode hides the merge settings", ctx do
      bind(ctx, ctx.app)
      {:ok, view, _html} = open(ctx)

      assert form_state(view).mode == :local
      assert in_portal?(view, @panel, "#project-github-mode-github[disabled]")
      refute in_portal?(view, @panel, "#project-github-merge-method")
      refute in_portal?(view, @panel, "#project-github-require-ci")
      refute in_portal?(view, @panel, "#project-github-delete-branch")
      refute in_portal?(view, @panel, "#project-github-merge-policy-on_verified")
      assert in_portal?(view, @panel, "#project-github-local-merge", "由人在本地审查与合并")
      assert portal_attr(view, @panel, "#project-github-save", "disabled") != nil
    end

    test "the rebind warning", ctx do
      bind(ctx, ctx.app)
      {:ok, view, _html} = open(ctx)
      refute in_portal?(view, @panel, "#project-github-local-rebind-warning")

      select(view, nil)

      assert in_portal?(
               view,
               @panel,
               "#project-github-local-rebind-warning",
               "已交付到原仓库的 hm/… 分支保留在原仓库"
             )

      assert in_portal?(view, @panel, "#project-github-local-base-branch[disabled]")

      select(view, ctx.web)
      assert in_portal?(view, @panel, "#project-github-local-rebind-warning", "需要在机器上手工清理")

      select(view, ctx.app)
      refute in_portal?(view, @panel, "#project-github-local-rebind-warning")
    end

    test "a member gets no panel", ctx do
      {:ok, view, _html} = open(ctx, :bob)
      refute open?(view, @panel)
    end

    test "without any local repository the dropdown only has 不绑定", ctx do
      Repo.delete_all(Helmsman.LocalRepositories.LocalRepository)
      {:ok, view, _html} = open(ctx)
      mode(view, "local")

      assert in_portal?(view, @panel, "#project-github-no-locals", "还没有机器向本工作区登记本地仓库")
    end
  end

  describe "saving (2.2)" do
    test "binding a local repository", ctx do
      {:ok, view, _html} = open(ctx)
      mode(view, "local")
      select(view, ctx.app)
      save(view, %{"local_repository_id" => "#{ctx.app.id}", "base_branch" => ""})

      assert_patch(view, ctx.base)
      refute open?(view, @panel)
      assert render(view) =~ "已保存仓库设置"
      assert project(ctx).local_repository_id == ctx.app.id
      assert project(ctx).base_branch == nil

      assert has_element?(view, "#project-local-repository-chip", "app")
      assert has_element?(view, "#project-local-repository-chip [data-machine]", "alice-mbp")
      assert has_element?(view, "#project-local-repository-chip [data-branch]", "main")
    end

    test "only the base branch", ctx do
      bind(ctx, ctx.app)
      {:ok, view, _html} = open(ctx)
      change(view, %{"local_repository_id" => "#{ctx.app.id}", "base_branch" => "develop"})

      assert ProjectGitHubForm.local_binding(form_state(view)) ==
               {ctx.app.id, [base_branch: "develop"]}

      save(view, %{"local_repository_id" => "#{ctx.app.id}", "base_branch" => "develop"})
      assert_patch(view, ctx.base)
      assert project(ctx).base_branch == "develop"
      assert has_element?(view, "#project-local-repository-chip [data-branch]", "develop")
    end

    test "unbinding", ctx do
      bind(ctx, ctx.app, "develop")
      {:ok, view, _html} = open(ctx)
      select(view, nil)
      save(view, %{"local_repository_id" => ""})

      assert_patch(view, ctx.base)
      assert project(ctx).local_repository_id == nil
      assert project(ctx).base_branch == nil
      refute has_element?(view, "#project-local-repository-chip")
    end

    test "bound to a GitHub repository by someone else meanwhile", ctx do
      {:ok, view, _html} = open(ctx)
      mode(view, "local")
      select(view, ctx.app)
      bind_github(ctx)
      save(view, %{"local_repository_id" => "#{ctx.app.id}"})

      assert open?(view, @panel)
      assert form_state(view).mode == :github

      assert in_portal?(
               view,
               @panel,
               "#project-github-repository-error",
               "项目已绑定 GitHub 仓库，先解除绑定"
             )

      assert in_portal?(view, @panel, "#project-github-mode-local[disabled]")
      assert project(ctx).local_repository_id == nil
      render_async(view)
    end

    test "the repository was removed", ctx do
      {:ok, view, _html} = open(ctx)
      mode(view, "local")
      select(view, ctx.app)
      ctx.app |> Ecto.Changeset.change(removed_at: DateTime.utc_now(:second)) |> Repo.update!()
      save(view, %{"local_repository_id" => "#{ctx.app.id}"})

      assert open?(view, @panel)
      assert in_portal?(view, @panel, "#project-github-local-repository-error", "本地仓库已被移除")
      refute Enum.any?(form_state(view).locals, &(&1.id == ctx.app.id))
      assert project(ctx).local_repository_id == nil
    end

    test "a changeset error stays on the base branch field", ctx do
      bind(ctx, ctx.app)
      {:ok, view, _html} = open(ctx)
      long = String.duplicate("b", 256)
      save(view, %{"local_repository_id" => "#{ctx.app.id}", "base_branch" => long})

      assert open?(view, @panel)
      assert [message] = form_state(view).errors[:base_branch]
      assert in_portal?(view, @panel, "#project-github-local-fields", message)
      assert project(ctx).base_branch == nil
    end
  end

  describe "display (2.3)" do
    test "the header", ctx do
      bind(ctx, ctx.app)
      {:ok, view, _html} = open(ctx, :bob, "")

      assert has_element?(view, ~s(#project-local-repository-chip[data-status="online"]), "app")
      assert has_element?(view, "#project-local-repository-chip", "· alice-mbp")
      assert has_element?(view, "#project-local-repository-chip [data-branch]", "main")
      refute has_element?(view, "#project-local-repository-chip [data-unavailable]")
      refute has_element?(view, "#project-repository")
    end

    test "an offline machine marks the header and the card", ctx do
      bind(ctx, ctx.app)
      ctx.app |> Ecto.Changeset.change(status: "offline") |> Repo.update!()

      {:ok, view, _html} = open(ctx, :bob, "")

      assert has_element?(
               view,
               ~s(#project-local-repository-chip[data-status="offline"] [data-unavailable])
             )

      assert render(view) =~ "所在机器离线，运行会等它上线后执行"

      {:ok, projects, _html} =
        live(log_in_user(ctx.conn, ctx.users.bob), "/w/#{ctx.ws.slug}/projects")

      assert has_element?(
               projects,
               ~s(#project-BOS-local-repository[data-status="offline"] [data-unavailable])
             )

      refute has_element?(projects, "#project-BOS-local-repository [data-branch]")
    end

    test "a member who does not own the machine never gets the path", ctx do
      bind(ctx, ctx.app)

      {:ok, view, html} = open(ctx, :bob, "")
      refute html =~ @path
      refute inspect(:sys.get_state(view.pid)) =~ @path

      {:ok, projects, html} =
        live(log_in_user(ctx.conn, ctx.users.bob), "/w/#{ctx.ws.slug}/projects")

      refute html =~ @path
      refute inspect(:sys.get_state(projects.pid)) =~ @path

      {:ok, view, _html} = open(ctx, :alice, "")
      assert inspect(:sys.get_state(view.pid)) =~ @path
    end
  end

  describe "live updates (2.4)" do
    test "the repository's status changes while the panel is open", ctx do
      {:ok, view, _html} = open(ctx)
      mode(view, "local")
      select(view, ctx.app)
      change(view, %{"local_repository_id" => "#{ctx.app.id}", "base_branch" => "develop"})

      ctx.app
      |> Ecto.Changeset.change(status: "unavailable", unavailable_reason: "not a git repository")
      |> Repo.update!()

      Events.broadcast(Events.topic(:workspace, ctx.ws.id), {:local_repositories_changed})

      eventually(fn ->
        in_portal?(view, @panel, "#project-github-local-status", "not a git repository")
      end)

      assert form_state(view).params.local_repository_id == ctx.app.id
      assert form_state(view).params.base_branch == "develop"
      assert form_state(view).mode == :local
    end

    test "the header chip follows the repository's status", ctx do
      bind(ctx, ctx.app)
      {:ok, view, _html} = open(ctx, :bob, "")
      ctx.app |> Ecto.Changeset.change(status: "offline") |> Repo.update!()
      Events.broadcast(Events.topic(:workspace, ctx.ws.id), {:local_repositories_changed})

      eventually(fn ->
        has_element?(view, ~s(#project-local-repository-chip[data-status="offline"]))
      end)
    end

    test "the projects page's card follows the repository's status", ctx do
      bind(ctx, ctx.app)

      {:ok, view, _html} =
        live(log_in_user(ctx.conn, ctx.users.bob), "/w/#{ctx.ws.slug}/projects")

      assert has_element?(view, ~s(#project-BOS-local-repository[data-status="online"]))

      ctx.app |> Ecto.Changeset.change(status: "offline") |> Repo.update!()
      Events.broadcast(Events.topic(:workspace, ctx.ws.id), {:local_repositories_changed})

      eventually(fn ->
        has_element?(view, ~s(#project-BOS-local-repository[data-status="offline"]))
      end)
    end

    test "bound elsewhere in the other mode: the panel follows the new base", ctx do
      {:ok, view, _html} = open(ctx)
      mode(view, "local")
      select(view, ctx.app)
      bind_github(ctx)
      Events.broadcast(Events.topic(:workspace, ctx.ws.id), {:projects_changed})

      eventually(fn -> form_state(view).mode == :github end)
      assert form_state(view).params.local_repository_id == nil
      assert in_portal?(view, @panel, "#project-github-mode-local[disabled]")
      render_async(view)
    end
  end
end
