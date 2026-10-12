defmodule HelmsmanWeb.ProjectLive.IndexTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.Projects

  setup %{conn: conn} do
    owner = user_fixture()
    ws = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, ws)

    users =
      for role <- [:admin, :member, :viewer], into: %{} do
        user = user_fixture()
        member_fixture(ws, user, role)
        {role, user}
      end

    %{conn: conn, ws: ws, slug: ws.slug, owner: owner_scope, users: users}
  end

  defp as(conn, users, role), do: log_in_user(conn, users[role])

  describe "cards" do
    test "show key, name, task count and link to the task list", ctx do
      project_fixture(ctx.owner, key: "BOS", name: "Bosun")
      for _ <- 1..12, do: task_fixture(ctx.owner, "BOS")

      conn = as(ctx.conn, ctx.users, :member)
      {:ok, view, html} = live(conn, "/w/#{ctx.slug}/projects")

      assert html =~ "<title"
      assert page_title(view) =~ "项目"
      assert has_element?(view, "header h1", "项目")
      assert has_element?(view, "#project-BOS", "BOS")
      assert has_element?(view, "#project-BOS", "Bosun")
      assert has_element?(view, "#project-BOS [data-count]", "12 个任务")
      assert has_element?(view, ~s(#project-BOS a[href="/w/#{ctx.slug}/p/BOS"]))

      {:ok, _view, html} =
        view |> element("#project-BOS a") |> render_click() |> follow_redirect(conn)

      assert html =~ "Bosun"
    end

    test "long descriptions are cut to 140 characters", ctx do
      description = String.duplicate("说", 150) <> String.duplicate("明", 50)
      project_fixture(ctx.owner, key: "BOS", name: "Bosun", description: description)

      {:ok, view, _html} = live(as(ctx.conn, ctx.users, :viewer), "/w/#{ctx.slug}/projects")

      text = view |> element("#project-BOS [data-description]") |> render()
      assert text =~ String.duplicate("说", 140) <> "…"
      refute text =~ String.duplicate("说", 141)
      refute text =~ "明"
    end

    test "archived projects only appear with 显示已归档", ctx do
      project_fixture(ctx.owner, key: "BOS", name: "Bosun")
      project_fixture(ctx.owner, key: "OLD", name: "Old")
      {:ok, _} = Projects.archive(ctx.owner, "OLD")
      conn = as(ctx.conn, ctx.users, :member)

      {:ok, view, _html} = live(conn, "/w/#{ctx.slug}/projects")
      assert has_element?(view, "#project-BOS")
      refute has_element?(view, "#project-OLD")
      assert has_element?(view, ~s(#show-archived[role=switch][aria-checked=false]))

      view |> element("#show-archived") |> render_click()
      assert_patch(view, "/w/#{ctx.slug}/projects?archived=1")
      assert has_element?(view, "#project-OLD [data-archived]", "已归档")
      refute has_element?(view, "#project-BOS [data-archived]")
      assert has_element?(view, ~s(#show-archived[aria-checked=true]))

      {:ok, direct, _html} = live(conn, "/w/#{ctx.slug}/projects?archived=1")
      assert has_element?(direct, "#project-OLD", "已归档")
    end

    test "no projects: admins get a create button, others a hint", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.users, :admin), "/w/#{ctx.slug}/projects")
      assert render(view) =~ "还没有项目"
      assert has_element?(view, "button, a", "新建项目")

      for role <- [:member, :viewer] do
        {:ok, view, _html} = live(as(ctx.conn, ctx.users, role), "/w/#{ctx.slug}/projects")
        assert render(view) =~ "请联系管理员创建项目"
        refute has_element?(view, "a", "新建项目")
        refute has_element?(view, "#new-project-button")
      end
    end
  end

  describe "新建项目" do
    test "creates the project and goes to its task list", ctx do
      conn = as(ctx.conn, ctx.users, :admin)
      {:ok, view, _html} = live(conn, "/w/#{ctx.slug}/projects")

      view |> element("#new-project-button") |> render_click()
      assert_patch(view, "/w/#{ctx.slug}/projects?panel=new-project")
      assert open?(view, "new-project")

      render_change(view, "change", %{project: %{key: "bos", name: ""}})
      assert portal_attr(view, "new-project", "#new-project-key", "value") == "BOS"

      {:ok, _task_view, html} =
        view
        |> render_submit("create", %{project: %{key: "bos", name: "Bosun"}})
        |> follow_redirect(conn, "/w/#{ctx.slug}/p/BOS")

      assert html =~ "Bosun"
    end

    test "an invalid key keeps the panel and the input", ctx do
      {:ok, view, _html} =
        live(as(ctx.conn, ctx.users, :admin), "/w/#{ctx.slug}/projects?panel=new-project")

      render_submit(view, "create", %{project: %{key: "1BOS", name: "Bosun"}})

      assert open?(view, "new-project")
      assert in_portal?(view, "new-project", "#new-project-key-error", "Key 须以大写字母开头")
      assert portal_attr(view, "new-project", "#new-project-key", "value") == "1BOS"
      assert portal_attr(view, "new-project", "#new-project-name", "value") == "Bosun"
    end

    test "a taken key is reported on the key field", ctx do
      project_fixture(ctx.owner, key: "BOS", name: "Bosun")

      {:ok, view, _html} =
        live(as(ctx.conn, ctx.users, :admin), "/w/#{ctx.slug}/projects?panel=new-project")

      render_submit(view, "create", %{project: %{key: "Bos", name: "Other", description: "d"}})

      assert in_portal?(view, "new-project", "#new-project-key-error", "Key 已被占用")
      assert portal_attr(view, "new-project", "#new-project-name", "value") == "Other"
      assert portal_text(view, "new-project", "#new-project-description") =~ "d"
    end

    test "an empty name is reported and the key kept", ctx do
      {:ok, view, _html} =
        live(as(ctx.conn, ctx.users, :admin), "/w/#{ctx.slug}/projects?panel=new-project")

      render_submit(view, "create", %{project: %{key: "BOS", name: ""}})

      assert in_portal?(view, "new-project", "#new-project-name-error")
      assert portal_attr(view, "new-project", "#new-project-key", "value") == "BOS"
    end

    test "members cannot open the panel", ctx do
      {:ok, view, _html} =
        live(as(ctx.conn, ctx.users, :member), "/w/#{ctx.slug}/projects?panel=new-project")

      refute open?(view, "new-project")
      refute has_element?(view, "#new-project-button")
    end
  end

  describe "live updates" do
    test "an archived project disappears unless archived ones are shown", ctx do
      project_fixture(ctx.owner, key: "BOS", name: "Bosun")
      conn = as(ctx.conn, ctx.users, :member)

      {:ok, view, _html} = live(conn, "/w/#{ctx.slug}/projects")
      {:ok, all, _html} = live(conn, "/w/#{ctx.slug}/projects?archived=1")
      assert has_element?(view, "#project-BOS")

      {:ok, _} = Projects.archive(ctx.owner, "BOS")

      refute has_element?(view, "#project-BOS")
      assert has_element?(all, "#project-BOS [data-archived]", "已归档")

      project_fixture(ctx.owner, key: "API", name: "Api")
      assert has_element?(view, "#project-API")
    end
  end
end
