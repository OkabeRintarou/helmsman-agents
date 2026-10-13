defmodule HelmsmanWeb.TaskLive.ProjectGitHubTest do
  @moduledoc """
  Spec web-github 项目的仓库与合并设置 / 项目显示绑定的仓库 (add-github-ui tasks 2.1–2.3).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{GitHub, Projects}
  alias HelmsmanWeb.ProjectGitHubForm

  @panel "project-github"

  setup %{conn: conn} do
    owner = user_fixture()
    ws = workspace_fixture(owner)

    scopes =
      for role <- [:admin, :member], into: %{owner: workspace_scope_fixture(owner, ws)} do
        user = user_fixture()
        member_fixture(ws, user, role)
        {role, workspace_scope_fixture(user, ws)}
      end

    project_fixture(scopes.owner, key: "BOS", name: "Bosun")

    %{conn: conn, ws: ws, scopes: scopes, base: "/w/#{ws.slug}/p/BOS"}
  end

  defp connect(ctx) do
    installation = installation_fixture(ctx.ws)

    Map.merge(ctx, %{
      installation: installation,
      web: repository_fixture(installation, owner: "acme", name: "web", default_branch: "main"),
      api: repository_fixture(installation, owner: "acme", name: "api", default_branch: "trunk")
    })
  end

  defp bind(ctx, repository, branch \\ nil) do
    {:ok, _} =
      Projects.update_github_settings(ctx.scopes.owner, "BOS", %{
        repository_id: repository.id,
        base_branch: branch
      })

    :ok
  end

  # Installation tokens, branch lists and branch checks. `branch_check` answers
  # `GET /repos/:owner/:name/branches/:branch`.
  defp stub(opts \\ []) do
    branches = Keyword.get(opts, :branches, ~w(main develop))
    test = self()

    branch_check =
      Keyword.get(opts, :branch_check, fn conn, branch ->
        if branch in branches,
          do: Req.Test.json(conn, %{"name" => branch}),
          else: not_found(conn)
      end)

    stub_github(fn conn ->
      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"POST", ["app", "installations", _id, "access_tokens"]} ->
          token_response(conn)

        {"GET", ["repos", _owner, _name, "branches"]} ->
          Req.Test.json(conn, Enum.map(branches, &%{"name" => &1}))

        {"GET", ["repos", _owner, _name, "branches", branch]} ->
          send(test, {:branch_check, branch})
          branch_check.(conn, branch)
      end
    end)
  end

  defp open(ctx, role \\ :admin, query \\ "?panel=project-github"),
    do: live(log_in_user(ctx.conn, ctx.scopes[role].user), ctx.base <> query)

  defp form_state(view), do: :sys.get_state(view.pid).socket.assigns.github

  defp change(view, params),
    do: render_change(view, "project_github_change", %{"project_github" => params})

  defp select(view, repository),
    do: render_click(view, "project_github_repository", %{"id" => repository && repository.id})

  defp save(view) do
    render_submit(view, "project_github_save", %{})
    render_async(view)
  end

  defp project(ctx) do
    {:ok, project} = Projects.get(ctx.scopes.owner, "BOS")
    project
  end

  describe "the panel" do
    setup ctx do
      stub()
      connect(ctx)
    end

    test "opens from the project menu for admins", ctx do
      {:ok, view, _html} = open(ctx, :admin, "")

      view |> element("#project-menu-github") |> render_click()
      assert_patch(view, ctx.base <> "?panel=project-github")
      assert open?(view, @panel)
      assert in_portal?(view, @panel, "#project-github-title", "仓库与合并 · BOS")
    end

    test "binding a repository with the default branch", ctx do
      {:ok, view, _html} = open(ctx)

      assert in_portal?(view, @panel, "#project-github-repository-none")
      assert in_portal?(view, @panel, "#project-github-repository-#{ctx.web.id}", "acme/web")
      assert portal_attr(view, @panel, "#project-github-base-branch", "disabled") != nil

      select(view, ctx.web)
      render_async(view)
      assert in_portal?(view, @panel, "#project-github-repository-value", "acme/web")
      assert portal_attr(view, @panel, "#project-github-base-branch", "placeholder") == "缺省：main"
      assert in_portal?(view, @panel, ~s(#project-github-branches option[value="develop"]))

      html = save(view)

      assert html =~ "已保存仓库与合并设置"
      assert_patch(view, ctx.base)
      refute open?(view, @panel)
      assert has_element?(view, "#project-repository-chip [data-repository]", "acme/web")
      assert has_element?(view, "#project-repository-chip [data-branch]", "main")
      assert project(ctx).repository_id == ctx.web.id
      refute_received {:branch_check, _}
    end

    test "the submit's fields are saved even without the last change", ctx do
      {:ok, view, _html} = open(ctx)
      select(view, ctx.web)

      render_submit(view, "project_github_save", %{
        "project_github" => %{
          "repository_id" => to_string(ctx.web.id),
          "base_branch" => "develop"
        }
      })

      assert render_async(view) =~ "已保存仓库与合并设置"
      assert_received {:branch_check, "develop"}
      assert {project(ctx).repository_id, project(ctx).base_branch} == {ctx.web.id, "develop"}
    end

    test "a missing base branch is shown under the field", ctx do
      :ok = bind(ctx, ctx.web)
      {:ok, view, _html} = open(ctx)

      change(view, %{"base_branch" => "release"})
      html = save(view)

      assert open?(view, @panel)
      assert html =~ "GitHub 上没有分支 release"
      assert in_portal?(view, @panel, "#project-github-base-branch-error", "GitHub 上没有分支 release")
      assert portal_attr(view, @panel, "#project-github-base-branch", "value") == "release"
      assert project(ctx).base_branch == nil
    end

    test "GitHub unreachable while saving keeps the input", ctx do
      :ok = bind(ctx, ctx.web)

      stub(
        branch_check: fn conn, _branch ->
          conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"message" => "Unavailable"})
        end
      )

      {:ok, view, _html} = open(ctx)
      change(view, %{"base_branch" => "develop"})
      save(view)

      assert in_portal?(view, @panel, "[role=alert]", "暂时无法连接 GitHub，设置没有保存")
      assert portal_attr(view, @panel, "#project-github-base-branch", "value") == "develop"
      assert project(ctx).base_branch == nil
    end

    test "the save runs in the background; closing the panel drops it", ctx do
      :ok = bind(ctx, ctx.web)
      test = self()

      stub(
        branch_check: fn conn, branch ->
          send(test, {:checking, self()})
          receive do: (:go -> Req.Test.json(conn, %{"name" => branch}))
        end
      )

      {:ok, view, _html} = open(ctx)
      change(view, %{"base_branch" => "develop"})
      render_submit(view, "project_github_save", %{})
      assert_receive {:checking, checker}

      assert in_portal?(view, @panel, "#project-github-save[disabled]", "保存中…")
      assert in_portal?(view, @panel, "fieldset[disabled] #project-github-base-branch")

      ref = Process.monitor(checker)
      render_patch(view, ctx.base)
      assert_receive {:DOWN, ^ref, :process, _, _}

      refute open?(view, @panel)
      refute render(view) =~ "已保存仓库与合并设置"
      assert project(ctx).base_branch == nil
    end

    test "a binding changed by someone else during the save", ctx do
      :ok = bind(ctx, ctx.web)
      docs = repository_fixture(ctx.installation, owner: "acme", name: "docs")
      counter = :counters.new(1, [])
      owner = ctx.scopes.owner

      # Admin B re-binds BOS during each branch check of A's save: the domain retries
      # once, then returns :stale. B ends on acme/api.
      stub(
        branch_check: fn conn, branch ->
          :counters.add(counter, 1, 1)
          target = if :counters.get(counter, 1) == 1, do: docs, else: ctx.api
          {:ok, _} = Projects.update_github_settings(owner, "BOS", %{repository_id: target.id})
          Req.Test.json(conn, %{"name" => branch})
        end
      )

      {:ok, view, _html} = open(ctx)
      change(view, %{"base_branch" => "develop", "merge_method" => "rebase"})
      save(view)

      assert open?(view, @panel)
      assert in_portal?(view, @panel, "[role=alert]", "刚被其他人修改")
      assert in_portal?(view, @panel, "#project-github-repository-value", "acme/api")
      assert portal_attr(view, @panel, "#project-github-base-branch", "value") in [nil, ""]

      state = form_state(view)
      assert state.base.repository_id == ctx.api.id
      assert ProjectGitHubForm.attrs(state) == %{merge_method: "rebase"}
      assert project(ctx).repository_id == ctx.api.id
    end

    test "re-binding warns about open PRs and clears the base branch", ctx do
      :ok = bind(ctx, ctx.web, "develop")
      {:ok, view, _html} = open(ctx)

      assert portal_attr(view, @panel, "#project-github-base-branch", "value") == "develop"
      refute in_portal?(view, @panel, "#project-github-rebind-warning")

      select(view, ctx.api)

      assert in_portal?(view, @panel, "#project-github-rebind-warning", "不再由 Helmsman 管理")
      assert portal_attr(view, @panel, "#project-github-base-branch", "value") in [nil, ""]

      select(view, nil)
      assert in_portal?(view, @panel, "#project-github-rebind-warning")
      assert in_portal?(view, @panel, "#project-github-merge-disabled", "绑定仓库后生效")
      assert ProjectGitHubForm.attrs(form_state(view)) == %{repository_id: nil, base_branch: nil}
    end

    test "only the merge policy is submitted when only it changed", ctx do
      :ok = bind(ctx, ctx.web)
      {:ok, view, _html} = open(ctx)

      assert portal_attr(view, @panel, "#project-github-save", "disabled") != nil

      change(view, %{
        "repository_id" => to_string(ctx.web.id),
        "base_branch" => "",
        "merge_policy" => "manual",
        "merge_method" => "squash",
        "require_ci" => "true",
        "delete_branch_after_merge" => "true"
      })

      assert ProjectGitHubForm.attrs(form_state(view)) == %{merge_policy: "manual"}
      assert portal_attr(view, @panel, "#project-github-save", "disabled") == nil

      assert save(view) =~ "已保存仓库与合并设置"
      saved = project(ctx)
      assert {saved.merge_policy, saved.repository_id} == {"manual", ctx.web.id}
    end

    test "an unavailable bound repository stays an option, marked", ctx do
      :ok = bind(ctx, ctx.api)
      ctx.api |> Ecto.Changeset.change(archived: true) |> Helmsman.Repo.update!()

      {:ok, view, _html} = open(ctx)

      assert in_portal?(view, @panel, "#project-github-repository-#{ctx.api.id}", "不可用")
      assert in_portal?(view, @panel, "#project-github-repository-value", "不可用")
    end

    test "a change elsewhere becomes the base; the user's edits stay", ctx do
      :ok = bind(ctx, ctx.web)
      {:ok, view, _html} = open(ctx)
      change(view, %{"merge_method" => "rebase"})

      {:ok, _} =
        Projects.update_github_settings(ctx.scopes.admin, "BOS", %{
          merge_policy: "manual",
          merge_method: "merge"
        })

      _ = render(view)
      state = form_state(view)
      assert state.params.merge_policy == "manual"
      assert state.params.merge_method == "rebase"
      assert ProjectGitHubForm.attrs(state) == %{merge_method: "rebase"}
    end
  end

  test "without a connected GitHub only 不绑定 is offered", ctx do
    {:ok, view, _html} = open(ctx)

    assert open?(view, @panel)
    assert in_portal?(view, @panel, "#project-github-repository-none", "不绑定")

    items =
      view
      |> portal(@panel)
      |> LazyHTML.query("#project-github-repository-menu [role=menuitemradio]")

    assert Enum.count(items) == 1

    assert in_portal?(
             view,
             @panel,
             ~s(#project-github-no-repositories a[href="/w/#{ctx.ws.slug}/settings/github"])
           )

    assert in_portal?(view, @panel, "#project-github-merge-disabled", "绑定仓库后生效")
    assert in_portal?(view, @panel, "fieldset[disabled] #project-github-merge-method")
    assert in_portal?(view, @panel, "#project-github-base-branch[disabled]")
  end

  test "a member opening the panel address gets no panel and no menu", ctx do
    {:ok, view, _html} = open(ctx, :member)

    refute has_element?(view, "#project-menu")
    refute open?(view, @panel)
  end

  describe "the bound repository in the header" do
    setup ctx do
      stub()
      connect(ctx)
    end

    test "an unavailable repository is marked", ctx do
      :ok = bind(ctx, ctx.web, "develop")
      {:ok, _} = GitHub.disconnect_installation(ctx.scopes.owner)

      {:ok, view, _html} = open(ctx, :member, "")

      assert has_element?(view, ~s(#project-repository-chip[data-available="false"]), "acme/web")
      assert has_element?(view, "#project-repository-chip [data-branch]", "develop")

      assert has_element?(
               view,
               "#project-repository-chip-unavailable[role=tooltip]",
               "仓库不可用，不会开 PR 或合并"
             )
    end

    test "unbinding elsewhere removes it", ctx do
      :ok = bind(ctx, ctx.web)
      {:ok, view, _html} = open(ctx, :member, "")

      assert has_element?(
               view,
               ~s(#project-repository-chip a[href="https://github.com/acme/web"][target="_blank"])
             )

      {:ok, _} = Projects.update_github_settings(ctx.scopes.admin, "BOS", %{repository_id: nil})

      refute has_element?(view, "#project-repository")
    end
  end
end
