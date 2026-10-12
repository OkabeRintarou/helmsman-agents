defmodule HelmsmanWeb.TaskLive.IndexTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.{Projects, Tasks}

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

    project_fixture(owner_scope, key: "BOS", name: "Bosun")

    %{
      conn: conn,
      ws: ws,
      slug: ws.slug,
      base: "/w/#{ws.slug}/p/BOS",
      scopes: scopes,
      member: scopes.member,
      owner_user: owner
    }
  end

  defp as(ctx, role), do: log_in_user(ctx.conn, ctx.scopes[role].user)

  defp row_ids(view) do
    view
    |> element("#tasks")
    |> render()
    |> then(&LazyHTML.from_fragment("<table>#{&1}</table>"))
    |> LazyHTML.query("#tasks > tr")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "task-", ""))
  end

  defp rows(view), do: if(has_element?(view, "#tasks"), do: row_ids(view), else: [])

  defp load_all(view) do
    if has_element?(view, "#tasks-more") do
      view |> element("#tasks-more") |> render_click()
      load_all(view)
    else
      view
    end
  end

  defp create(ctx, attrs \\ %{}), do: task_fixture(ctx.member, "BOS", attrs)

  describe "task list" do
    test "rows in update order with every column", ctx do
      t1 = create(ctx, %{title: "First", labels: ["api"], priority: "high"})
      create(ctx, %{title: "Second"})

      {:ok, _} =
        Tasks.update(ctx.member, t1.ident, %{assignee: ctx.member.actor.name}, t1.lock_version)

      {:ok, view, _html} = live(as(ctx, :member), ctx.base)

      assert row_ids(view) == ["BOS-1", "BOS-2"]
      row = "#tasks tr:first-child"
      assert has_element?(view, row <> " [data-status=new]")
      assert has_element?(view, row <> ~s( a[href="/w/#{ctx.slug}/t/BOS-1"]), "BOS-1")
      assert has_element?(view, row, "First")
      assert has_element?(view, row <> ~s( button[data-label="api"]))
      assert has_element?(view, row <> " svg[data-priority='3']")
      assert has_element?(view, row <> " [data-actor-kind=human]")
      assert has_element?(view, row <> " time")
      assert has_element?(view, ~s(#tasks tr[phx-click*="/t/BOS-1"]))
    end

    test "tasks waiting for an answer are marked (待回答的任务)", ctx do
      task_fixture(ctx.scopes.owner, "BOS")
      task_fixture(ctx.scopes.owner, "BOS")

      {:ok, _} =
        Helmsman.Feedback.add(ctx.scopes.member, "BOS-2", %{kind: "question", content: "?"})

      {:ok, view, _html} = live(as(ctx, :member), ctx.base)

      assert has_element?(view, ~s(#task-BOS-2 [data-open-question][aria-label="待回答"]))
      refute has_element?(view, "#task-BOS-1 [data-open-question]")
    end

    test "header with breadcrumb and title", ctx do
      {:ok, view, _html} = live(as(ctx, :viewer), ctx.base)

      assert has_element?(view, ~s(header nav a[href="/w/#{ctx.slug}/projects"]), "项目")
      assert has_element?(view, "header h1", "Bosun")
      assert page_title(view) =~ "Bosun"
      refute has_element?(view, "#project-new-task")
      assert render(view) =~ "还没有任务"
    end

    test "loads 50 rows at a time", ctx do
      for _ <- 1..60, do: create(ctx)
      {:ok, view, _html} = live(as(ctx, :member), ctx.base)

      assert length(row_ids(view)) == 50
      view |> element("#tasks-more") |> render_click()
      assert length(row_ids(view)) == 60
      refute has_element?(view, "#tasks-more")
    end

    test "加载更多 only appears with more than 50 tasks", ctx do
      for _ <- 1..50, do: create(ctx)
      {:ok, view, _html} = live(as(ctx, :member), ctx.base)
      refute has_element?(view, "#tasks-more")

      create(ctx)
      {:ok, view, _html} = live(as(ctx, :member), ctx.base)
      assert has_element?(view, "#tasks-more")
      assert length(row_ids(view)) == 50
    end

    test "a lower-case key goes to the canonical address", ctx do
      conn = as(ctx, :member)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/w/#{ctx.slug}/p/bos?status=new")

      assert to == ctx.base <> "?status=new"
      {:ok, view, _html} = live(conn, to)
      assert has_element?(view, "#task-filters-chip-status", "新建")
    end

    test "unknown projects and other workspaces' projects are 404", ctx do
      other_owner = user_fixture()
      other = workspace_fixture(other_owner)
      project_fixture(workspace_scope_fixture(other_owner, other), key: "OTH", name: "Other")

      conn = as(ctx, :member)
      assert_raise HelmsmanWeb.NotFoundError, fn -> live(conn, "/w/#{ctx.slug}/p/NOPE") end
      assert_raise HelmsmanWeb.NotFoundError, fn -> live(conn, "/w/#{ctx.slug}/p/OTH") end
    end
  end

  describe "filters" do
    setup ctx do
      alice = ctx.member.actor.name

      create(ctx, %{title: "new api", labels: ["api"]})
      t2 = create(ctx, %{title: "doing api", labels: ["api", "backend"], assignee: alice})
      {:ok, _} = Tasks.transition(ctx.member, t2.ident, "in_progress", %{})
      create(ctx, %{title: "new ui", labels: ["ui"], assignee: alice})
      t4 = create(ctx, %{title: "cancelled api", labels: ["api"]})
      {:ok, _} = Tasks.transition(ctx.member, t4.ident, "cancelled", %{comment: "x"})

      %{alice: alice}
    end

    test "status and label from the URL", ctx do
      {:ok, view, _html} =
        live(as(ctx, :member), ctx.base <> "?status=new,in_progress&label=api")

      assert has_element?(view, "#task-filters-chip-status", "新建、进行中")
      assert has_element?(view, "#task-filters-chip-label", "api")
      assert Enum.sort(row_ids(view)) == ["BOS-1", "BOS-2"]
      refute has_element?(view, "[data-hm-filter-input]")
    end

    test "quick views patch the status and keep label and assignee", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.base <> "?label=api&assignee=" <> ctx.alice)
      assert has_element?(view, ~s(#task-view-all[aria-current="page"]))

      href = view |> element("#task-view-closed") |> render() |> attr("href")
      assert href =~ "label=api"
      assert href =~ "assignee="

      {:ok, view, _html} = live(as(ctx, :member), ctx.base)
      view |> element("#task-view-closed") |> render_click()
      assert_patch(view, ctx.base <> "?status=verified%2Crejected%2Ccancelled")
      assert has_element?(view, ~s(#task-view-closed[aria-current="page"]))
      assert row_ids(view) == ["BOS-4"]
    end

    test "未指派 and a named assignee", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.base)

      view |> element(~s([id="filter-assignee-@none"])) |> render_click()
      assert_patch(view, ctx.base <> "?assignee=%40none")
      assert Enum.sort(row_ids(view)) == ["BOS-1", "BOS-4"]
      assert has_element?(view, "#task-filters-chip-assignee", "未指派")

      {:ok, view, _html} = live(as(ctx, :member), ctx.base <> "?assignee=" <> ctx.alice)
      assert Enum.sort(row_ids(view)) == ["BOS-2", "BOS-3"]
    end

    test "clicking a row's label filters without opening the task", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.base)

      view |> element(~s(#task-BOS-2 button[data-label="backend"])) |> render_click()
      assert_patch(view, ctx.base <> "?label=backend")
      assert row_ids(view) == ["BOS-2"]
    end

    test "unknown statuses are ignored; empty results can be cleared", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.base <> "?status=doing")
      refute has_element?(view, "#task-filters-chip-status")
      assert length(row_ids(view)) == 4

      {:ok, view, _html} = live(as(ctx, :member), ctx.base <> "?label=nothing")
      assert render(view) =~ "没有符合条件的结果"
      view |> element("button", "清除筛选") |> render_click()
      assert_patch(view, ctx.base)
      assert length(row_ids(view)) == 4
    end

    test "similar identity names filter separately (code-review-1 R1)", ctx do
      names = ["keel/dev", "keel-dev", "keel.dev"]

      for {name, i} <- Enum.with_index(names, 5) do
        agent_fixture(ctx.ws, ctx.owner_user, name)
        create(ctx, %{assignee: name, title: "for #{name}"})
        assert {:ok, %{ident: ident}} = Tasks.get(ctx.member, "BOS-#{i}")
        assert ident == "BOS-#{i}"
      end

      {:ok, view, _html} = live(as(ctx, :member), ctx.base)

      for {name, i} <- Enum.with_index(names, 5) do
        view |> element(~s([id="filter-assignee-#{name}"])) |> render_click()
        assert row_ids(view) == ["BOS-#{i}"]
        render_patch(view, ctx.base)
      end
    end

    test "options: project labels and assignable identities", ctx do
      other = project_fixture(ctx.scopes.owner, key: "OTH", name: "Other")
      task_fixture(ctx.member, other.key, %{labels: ["elsewhere"]})
      owner_user = ctx.owner_user
      agent_fixture(ctx.ws, owner_user, "keel/dev")
      agent_fixture(ctx.ws, owner_user, "old/agent", %{disabled_at: DateTime.utc_now(:second)})

      {:ok, view, _html} = live(as(ctx, :member), ctx.base)
      menu = view |> element("#task-filters-menu-popover") |> render()

      for label <- ~w(api backend ui), do: assert(menu =~ ~s(id="filter-label-#{label}"))
      for name <- ["keel/dev"], do: assert(menu =~ ~s(id="filter-assignee-#{name}"))
      refute menu =~ "elsewhere"
      assert menu =~ "未指派"
      assert menu =~ ctx.alice
      assert menu =~ "keel/dev"
      refute menu =~ "old/agent"
      refute menu =~ ~s(id="filter-assignee-helmsman")

      create(ctx, %{labels: ["fresh"]})
      assert view |> element("#task-filters-menu-popover") |> render() =~ "filter-label-fresh"
    end
  end

  describe "live updates" do
    test "a task created elsewhere appears at the top", ctx do
      create(ctx)
      {:ok, view, _html} = live(as(ctx, :member), ctx.base)
      pid = view.pid

      task_fixture(ctx.scopes.admin, "BOS", %{title: "Fresh"})
      assert row_ids(view) == ["BOS-2", "BOS-1"]
      assert has_element?(view, "#tasks tr:first-child", "Fresh")
      assert has_element?(view, "#tasks tr:first-child span[id^=task-BOS-2-v]")
      assert view.pid == pid
    end

    test "an edited task moves to the top with its new title", ctx do
      for _ <- 1..5, do: create(ctx)
      {:ok, view, _html} = live(as(ctx, :member), ctx.base)
      assert Enum.at(row_ids(view), 3) == "BOS-2"

      {:ok, t} = Tasks.get(ctx.member, "BOS-2")
      {:ok, _} = Tasks.update(ctx.scopes.admin, "BOS-2", %{title: "Renamed"}, t.lock_version)

      assert hd(row_ids(view)) == "BOS-2"
      assert has_element?(view, "#tasks tr:first-child", "Renamed")
    end

    test "a task no longer passing the filter is removed", ctx do
      create(ctx, %{assignee: ctx.member.actor.name})
      create(ctx)
      {:ok, view, _html} = live(as(ctx, :member), ctx.base <> "?status=new")
      assert Enum.sort(row_ids(view)) == ["BOS-1", "BOS-2"]

      {:ok, _} = Tasks.transition(ctx.scopes.admin, "BOS-1", "in_progress", %{})
      assert row_ids(view) == ["BOS-2"]

      {:ok, view, _html} = live(as(ctx, :member), ctx.base <> "?assignee=@none")
      {:ok, t} = Tasks.get(ctx.member, "BOS-2")

      {:ok, _} =
        Tasks.update(ctx.member, "BOS-2", %{assignee: ctx.member.actor.name}, t.lock_version)

      refute "BOS-2" in rows(view)
    end

    test "加载更多 after live changes shows every matching task once, in order", ctx do
      for _ <- 1..60, do: create(ctx, %{labels: ["api"]})
      {:ok, view, _html} = live(as(ctx, :member), ctx.base <> "?label=api")
      loaded = row_ids(view)
      assert length(loaded) == 50
      refute "BOS-1" in loaded

      # (a) a loaded task leaves the filter, (b) an unloaded one is edited,
      # (c) a new matching task is created.
      {:ok, a} = Tasks.get(ctx.member, hd(loaded))
      {:ok, _} = Tasks.update(ctx.scopes.admin, a.ident, %{labels: ["ui"]}, a.lock_version)
      {:ok, b} = Tasks.get(ctx.member, "BOS-1")
      {:ok, _} = Tasks.update(ctx.scopes.admin, "BOS-1", %{title: "Moved"}, b.lock_version)
      create(ctx, %{labels: ["api"]})

      assert_complete(view, ctx)
    end

    test "every loaded row leaving the filter loads the next page (code-review-1 R2)", ctx do
      for _ <- 1..51, do: create(ctx, %{labels: ["api"]})
      {:ok, view, _html} = live(as(ctx, :member), ctx.base <> "?label=api")
      loaded = row_ids(view)
      assert length(loaded) == 50

      for ident <- loaded do
        {:ok, t} = Tasks.get(ctx.member, ident)
        {:ok, _} = Tasks.update(ctx.scopes.admin, ident, %{labels: ["ui"]}, t.lock_version)
      end

      refute render(view) =~ "没有符合条件的结果"
      assert row_ids(view) == ["BOS-1"]
      assert_complete(view, ctx)
    end

    test "changes between two 加载更多 pages", ctx do
      for _ <- 1..110, do: create(ctx, %{labels: ["api"]})
      {:ok, view, _html} = live(as(ctx, :member), ctx.base <> "?label=api")
      view |> element("#tasks-more") |> render_click()
      loaded = row_ids(view)
      assert length(loaded) == 100

      {:ok, a} = Tasks.get(ctx.member, Enum.at(loaded, 70))
      {:ok, _} = Tasks.update(ctx.scopes.admin, a.ident, %{labels: []}, a.lock_version)
      {:ok, b} = Tasks.get(ctx.member, "BOS-3")
      {:ok, _} = Tasks.update(ctx.scopes.admin, "BOS-3", %{title: "Moved"}, b.lock_version)

      assert_complete(view, ctx)
    end

    defp assert_complete(view, ctx) do
      ids = view |> load_all() |> row_ids()
      expected = all_matching(ctx.member, label: "api")

      assert ids == Enum.uniq(ids)
      assert ids == expected
    end

    defp all_matching(scope, opts, before \\ nil, acc \\ []) do
      {:ok, tasks} = Tasks.list(scope, "BOS", Keyword.merge(opts, limit: 200, before: before))

      case tasks do
        [] ->
          Enum.map(acc, & &1.ident)

        _ ->
          all_matching(
            scope,
            opts,
            {List.last(tasks).updated_at, List.last(tasks).id},
            acc ++ tasks
          )
      end
    end
  end

  describe "project menu" do
    test "admins edit the name; the key stays", ctx do
      conn = as(ctx, :admin)
      {:ok, view, _html} = live(conn, ctx.base)

      view |> element("#project-menu-edit") |> render_click()
      assert_patch(view, ctx.base <> "?panel=edit-project")
      assert portal_attr(view, "edit-project", "#edit-project-key", "readonly") != nil
      assert in_portal?(view, "edit-project", "#edit-project-key-help", "不能修改")

      render_submit(view, "edit_project_save", %{project: %{name: "Bosun 2", description: ""}})
      assert_patch(view, ctx.base)
      refute open?(view, "edit-project")
      assert has_element?(view, "header h1", "Bosun 2")
      assert has_element?(view, ~s(#hm-nav-projects a[href="#{ctx.base}"]), "Bosun 2")
      assert {:ok, %{key: "BOS", name: "Bosun 2"}} = Projects.get(ctx.member, "bos")
    end

    test "archive and restore", ctx do
      create(ctx)
      {:ok, view, _html} = live(as(ctx, :admin), ctx.base)
      # An unarchived project's 新建任务 is a working link, not an inert button.
      assert has_element?(view, ~s(a#project-new-task[href="#{ctx.base}?panel=new"]))

      assert in_portal?(
               view,
               "archive-project-dialog",
               "#archive-project-dialog-description",
               "已有任务照常可读"
             )

      render_click(view, "archive", %{})
      assert has_element?(view, "#project-archived-banner", "此项目已归档")
      assert has_element?(view, ~s(#project-new-task[aria-disabled="true"]))
      assert render(view) =~ "项目已归档"
      refute has_element?(view, ~s(#hm-nav-projects a[href="#{ctx.base}"]))
      assert row_ids(view) == ["BOS-1"]

      view |> element("#project-menu-unarchive") |> render_click()
      refute has_element?(view, "#project-archived-banner")
      refute has_element?(view, ~s(#project-new-task[aria-disabled="true"]))
      assert has_element?(view, ~s(#hm-nav-projects a[href="#{ctx.base}"]))
    end

    test "members see no project menu and cannot open the edit panel", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.base <> "?panel=edit-project")
      refute has_element?(view, "#project-menu")
      refute open?(view, "edit-project")
    end

    test "an archive from another window shows the banner", ctx do
      {:ok, view, _html} = live(as(ctx, :member), ctx.base)
      {:ok, _} = Projects.archive(ctx.scopes.owner, "BOS")
      assert has_element?(view, "#project-archived-banner")
    end
  end

  defp attr(html, name) do
    [value | _] =
      html |> LazyHTML.from_fragment() |> LazyHTML.query("a") |> LazyHTML.attribute(name)

    value
  end
end
