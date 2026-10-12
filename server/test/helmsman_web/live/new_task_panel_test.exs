defmodule HelmsmanWeb.NewTaskPanelTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.{Projects, Repo, Tasks}

  @panel "new-task-dialog"

  setup %{conn: conn} do
    owner = user_fixture()
    ws = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, ws)

    scopes =
      for role <- [:admin, :member, :viewer], into: %{owner: owner_scope} do
        user = user_fixture()
        member_fixture(ws, user, role)
        {role, workspace_scope_fixture(user, ws)}
      end

    %{conn: conn, ws: ws, slug: ws.slug, scopes: scopes, owner_user: owner}
  end

  defp as(ctx, role), do: log_in_user(ctx.conn, ctx.scopes[role].user)

  defp projects(ctx) do
    project_fixture(ctx.scopes.owner, key: "BOS", name: "Bosun")
    project_fixture(ctx.scopes.owner, key: "API", name: "Api")
    project_fixture(ctx.scopes.owner, key: "OLD", name: "Old")
    {:ok, _} = Projects.archive(ctx.scopes.owner, "OLD")
    task_fixture(ctx.scopes.owner, "API")
    :ok
  end

  defp selected_project(view),
    do: portal_attr(view, @panel, "#new-task-project option[selected]", "value")

  defp submit(view, params) do
    view
    |> with_target("#new-task-panel")
    |> render_submit("submit", %{task: params})
  end

  defp change(view, params) do
    view
    |> with_target("#new-task-panel")
    |> render_change("change", %{task: params})
  end

  defp form_params(overrides) do
    Map.merge(
      %{
        project: "BOS",
        title: "",
        description: "",
        priority: "medium",
        labels: "",
        assignee: "",
        continuous: "false"
      },
      overrides
    )
  end

  describe "opening" do
    setup ctx, do: projects(ctx)

    test "the default project follows the page", ctx do
      conn = as(ctx, :member)

      {:ok, view, _} = live(conn, "/w/#{ctx.slug}/p/BOS?panel=new")
      assert open?(view, @panel)
      assert selected_project(view) == "BOS"

      {:ok, view, _} = live(conn, "/w/#{ctx.slug}/t/API-1?panel=new")
      assert selected_project(view) == "API"

      {:ok, view, _} = live(conn, "/w/#{ctx.slug}/projects?panel=new")
      assert selected_project(view) == "API"

      options =
        view
        |> portal(@panel)
        |> LazyHTML.query("#new-task-project option")
        |> LazyHTML.attribute("value")

      assert options == ["API", "BOS"]
    end

    test "closing drops only the panel parameter", ctx do
      {:ok, view, _} = live(as(ctx, :member), "/w/#{ctx.slug}/p/BOS?status=new&panel=new")

      cancel = portal_attr(view, @panel, "#new-task-dialog", "data-cancel")
      assert cancel =~ ~s("href":"/w/#{ctx.slug}/p/BOS?status=new")

      render_patch(view, "/w/#{ctx.slug}/p/BOS?status=new")
      refute open?(view, @panel)
    end

    test "viewers never get the panel", ctx do
      {:ok, view, _} = live(as(ctx, :viewer), "/w/#{ctx.slug}/p/BOS?panel=new")
      refute open?(view, @panel)
      refute has_element?(view, "[data-hm-new-task]")
    end
  end

  describe "without projects" do
    test "admins get a link to create one", ctx do
      {:ok, view, _} = live(as(ctx, :admin), "/w/#{ctx.slug}/projects?panel=new")
      assert in_portal?(view, @panel, "#new-task-no-projects", "还没有项目")

      assert portal_attr(view, @panel, "#new-task-no-projects a", "href") ==
               "/w/#{ctx.slug}/projects?panel=new-project"

      {:ok, view, _} = live(as(ctx, :member), "/w/#{ctx.slug}?panel=new")
      assert in_portal?(view, @panel, "#new-task-no-projects", "还没有项目")
      refute in_portal?(view, @panel, "#new-task-no-projects a")
    end
  end

  describe "submitting" do
    setup ctx, do: projects(ctx)

    test "creates the task and opens it", ctx do
      {:ok, view, _} = live(as(ctx, :member), "/w/#{ctx.slug}/p/BOS?panel=new")

      submit(view, form_params(%{title: "修复登录"}))
      assert_redirect(view, "/w/#{ctx.slug}/t/BOS-1")
      assert {:ok, %{title: "修复登录"}} = Tasks.get(ctx.scopes.member, "BOS-1")
    end

    test "连续创建 keeps the panel open and reports each task", ctx do
      {:ok, view, _} = live(as(ctx, :member), "/w/#{ctx.slug}/p/BOS?panel=new")

      submit(
        view,
        form_params(%{
          title: "One",
          description: "d",
          labels: "api",
          priority: "high",
          continuous: "true"
        })
      )

      assert in_portal?(view, @panel, "#new-task-created[role=status][aria-live=polite]", "已创建")
      assert in_portal?(view, @panel, "#new-task-created a", "BOS-1")
      assert portal_attr(view, @panel, "#new-task-title", "value") in [nil, ""]
      assert portal_text(view, @panel, "#new-task-description") |> String.trim() == ""
      assert portal_attr(view, @panel, "#new-task-labels", "value") == "api"
      assert portal_attr(view, @panel, "#new-task-priority option[selected]", "value") == "high"
      assert portal_attr(view, @panel, "#new-task-continuous", "checked") != nil

      submit(
        view,
        form_params(%{title: "Two", labels: "api", priority: "high", continuous: "true"})
      )

      assert in_portal?(view, @panel, "#new-task-created a", "BOS-2")
      refute in_portal?(view, @panel, "#new-task-created a", "BOS-1")
      assert open?(view, @panel)
      refute_redirected(view)
      refute_patched(view)

      change(view, form_params(%{title: "T", labels: "api", continuous: "true"}))
      refute in_portal?(view, @panel, "#new-task-created a")
    end

    test "an empty title is reported and the input kept", ctx do
      {:ok, view, _} = live(as(ctx, :member), "/w/#{ctx.slug}/p/BOS?panel=new")

      submit(view, form_params(%{title: "", description: "keep me", labels: "api"}))
      assert in_portal?(view, @panel, "#new-task-title-error", "不能为空")
      assert portal_text(view, @panel, "#new-task-description") =~ "keep me"
      assert portal_attr(view, @panel, "#new-task-labels", "value") == "api"
      assert open?(view, @panel)
    end

    test "labels are split on commas and normalized", ctx do
      {:ok, view, _} = live(as(ctx, :member), "/w/#{ctx.slug}/p/BOS?panel=new")
      submit(view, form_params(%{title: "x", labels: " Backend, api "}))
      assert {:ok, %{labels: ["backend", "api"]}} = Tasks.get(ctx.scopes.member, "BOS-1")
    end

    test "assignee options come from the assignable identities", ctx do
      agent = agent_fixture(ctx.ws, ctx.owner_user, "keel/dev")
      {:ok, view, _} = live(as(ctx, :member), "/w/#{ctx.slug}/p/BOS?panel=new")

      options =
        view
        |> portal(@panel)
        |> LazyHTML.query("#new-task-assignee option")
        |> LazyHTML.attribute("value")

      assert "" in options
      assert ctx.scopes.member.actor.name in options
      assert agent.name in options
      refute "helmsman" in options

      # Disabled after the panel opened: the domain rejects it.
      agent |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
      submit(view, form_params(%{title: "x", assignee: agent.name, description: "keep"}))

      assert in_portal?(view, @panel, "#new-task-assignee-error", "已停用")
      assert portal_text(view, @panel, "#new-task-description") =~ "keep"
    end

    test "a project archived before submitting", ctx do
      {:ok, view, _} = live(as(ctx, :member), "/w/#{ctx.slug}/p/BOS?panel=new")
      {:ok, _} = Projects.archive(ctx.scopes.owner, "BOS")

      submit(view, form_params(%{title: "x"}))
      assert in_portal?(view, @panel, "#new-task-project-error", "项目已归档，不能新建任务")
    end
  end

  describe "assigning a managed agent (web-runs 新建任务时指派托管 Agent)" do
    setup ctx do
      projects(ctx)
      member = ctx.scopes.member
      Helmsman.AgentsFixtures.managed_agent_fixture(member, %{name: "keel/dev"})
      :ok
    end

    defp runs_of_task(scope, ident) do
      {:ok, task} = Tasks.get(scope, ident)
      Helmsman.RunsFixtures.runs_of(task.id)
    end

    test "新建并开始", ctx do
      {:ok, view, _} = live(as(ctx, :member), "/w/#{ctx.slug}/p/BOS?panel=new")

      refute in_portal?(view, @panel, "#new-task-start")
      change(view, form_params(%{title: "x", assignee: "keel/dev"}))
      assert in_portal?(view, @panel, "#new-task-start[checked]")

      submit(view, form_params(%{title: "x", assignee: "keel/dev", start: "true"}))
      {path, flash} = assert_redirect(view)
      assert path == "/w/#{ctx.slug}/t/BOS-1"
      assert flash["info"] == "已派发给 keel/dev"
      assert [%{status: :queued}] = runs_of_task(ctx.scopes.member, "BOS-1")
    end

    test "新建但不开始", ctx do
      {:ok, view, _} = live(as(ctx, :member), "/w/#{ctx.slug}/p/BOS?panel=new")
      change(view, form_params(%{title: "x", assignee: "keel/dev"}))

      submit(view, form_params(%{title: "x", assignee: "keel/dev", start: "false"}))
      {_path, flash} = assert_redirect(view)
      assert flash["info"] == "已指派给 keel/dev，暂不开始"
      assert {:ok, %{assignee: %{name: "keel/dev"}}} = Tasks.get(ctx.scopes.member, "BOS-1")
      assert runs_of_task(ctx.scopes.member, "BOS-1") == []
    end

    test "an agent the user cannot start shows why", ctx do
      {:ok, view, _} = live(as(ctx, :admin), "/w/#{ctx.slug}/p/BOS?panel=new")
      change(view, form_params(%{title: "x", assignee: "keel/dev"}))

      assert in_portal?(view, @panel, "#new-task-start")
      assert in_portal?(view, @panel, "#new-task-start-note", "你无权触发 keel/dev")
    end
  end
end
