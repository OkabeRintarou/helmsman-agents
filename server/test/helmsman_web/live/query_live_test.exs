defmodule HelmsmanWeb.QueryLiveTest do
  @moduledoc """
  The BQL page (spec web-query, add-search-query-ui D3–D7) against the real BQL and
  saved-filter domain. Timeouts are in `HelmsmanWeb.QueryLiveTimeoutTest`.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures, only: [agent_actor: 2, run_fixture: 2]

  alias Helmsman.{Filters, Members, Repo}
  alias Helmsman.Filters.SavedFilter
  alias HelmsmanWeb.{QueryComponents, QueryLive}

  setup %{conn: conn} do
    alice = user_fixture(%{display_name: "Alice"})
    ws = workspace_fixture(alice, %{name: "Acme"})
    alice_scope = workspace_scope_fixture(alice, ws)

    users =
      for {name, role} <- [bob: :member, carol: :admin, vic: :viewer], into: %{} do
        user = user_fixture(%{display_name: String.capitalize(Atom.to_string(name))})
        membership = member_fixture(ws, user, role)

        {name, %{user: user, scope: workspace_scope_fixture(user, ws), membership: membership}}
      end

    project_fixture(alice_scope, key: "BOS", name: "Bosun")

    %{
      conn: conn,
      ws: ws,
      slug: ws.slug,
      alice: %{user: alice, scope: alice_scope},
      bob: users.bob,
      carol: users.carol,
      vic: users.vic
    }
  end

  defp open(conn, who, path), do: live(log_in_user(conn, who.user), path)

  defp query_path(slug, params \\ []),
    do: "/w/#{slug}/query" <> if(params == [], do: "", else: "?" <> URI.encode_query(params))

  defp editor(view) do
    view |> element("#query-bql") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp type(view, bql), do: view |> form("#query-form", query: %{bql: bql}) |> render_change()
  defp run(view, bql), do: view |> form("#query-form", query: %{bql: bql}) |> render_submit()

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#query-tasks tr[id^=query-task-]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "query-task-", ""))
  end

  defp create_filter(who, name, bql, visibility) do
    {:ok, filter} =
      Filters.create(who.scope, %{name: name, bql: bql, visibility: visibility})

    filter
  end

  defp stored(id), do: Repo.get(SavedFilter, id)

  # A saved query that no longer parses (e.g. after a grammar change) bypasses the changeset.
  defp break_filter(filter),
    do: Repo.update_all(from(f in SavedFilter, where: f.id == ^filter.id), set: [bql: "foo = 1"])

  describe "BQL 页" do
    test "运行并分享: the query goes into the URL and runs as each member", ctx do
      %{conn: conn, slug: slug, alice: alice, bob: bob} = ctx
      mine = task_fixture(alice.scope, "BOS", %{assignee: alice.scope.actor.name})
      bobs = task_fixture(alice.scope, "BOS", %{assignee: bob.scope.actor.name})
      task_fixture(alice.scope, "BOS")

      bql = "status = new AND assignee = currentUser()"
      {:ok, view, _html} = open(conn, alice, query_path(slug))

      assert has_element?(view, ~s(#query-bql[phx-hook="Editor"][data-submit="mod-enter-form"]))

      run(view, bql)
      assert_patch(view, query_path(slug, bql: bql))
      assert row_ids(view) == [mine.ident]
      assert has_element?(view, "#query-total", "共 1 个任务")

      {:ok, view, _html} = open(conn, bob, query_path(slug, bql: bql))
      assert editor(view) == bql
      assert row_ids(view) == [bobs.ident]
    end

    test "示例查询: a click fills the editor and runs", %{conn: conn, slug: slug, alice: alice} do
      {:ok, view, _html} = open(conn, alice, query_path(slug))
      assert has_element?(view, "#query-examples")
      refute has_element?(view, "#query-results")

      view |> element("#query-examples button", "pr = open AND ci = failure") |> render_click()

      assert_patch(view, query_path(slug, bql: "pr = open AND ci = failure"))
      assert editor(view) == "pr = open AND ci = failure"
      assert has_element?(view, "#query-total", "共 0 个任务")
      refute has_element?(view, "#query-examples")
    end

    test "字段速查: collapsed by default, lists every field; a click appends it", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug))
      refute has_element?(view, "#query-fields")

      view |> element("#query-toggle-fields") |> render_click()
      assert has_element?(view, ~s(#query-toggle-fields[aria-expanded="true"]))
      assert has_element?(view, "#query-fields", "AND / OR / NOT")

      assert has_element?(view, "#query-field-status [data-values]", "in_progress")
      assert has_element?(view, ~s(#query-field-status [data-sortable="true"]))
      assert has_element?(view, "#query-field-labels [data-aliases]", "label")
      assert has_element?(view, ~s(#query-field-labels [data-sortable="false"]))
      assert has_element?(view, "#query-field-updated [data-values]", "-7d")

      type(view, "project = BOS AND")
      view |> element("#query-field-status button") |> render_click()
      assert editor(view) == "project = BOS AND status "
    end

    test "the sidebar's 查询 item opens the page and is current there", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug))

      assert has_element?(
               view,
               ~s(#hm-nav-filters a[href="/w/#{ctx.slug}/query"][aria-current="page"]),
               "查询"
             )

      assert page_title(view) =~ "查询"
    end

    test "viewers open the page and run queries", ctx do
      task = task_fixture(ctx.alice.scope, "BOS")
      {:ok, view, _html} = open(ctx.conn, ctx.vic, query_path(ctx.slug, bql: "project = BOS"))
      assert row_ids(view) == [task.ident]
      refute has_element?(view, "#query-save-new")
    end
  end

  describe "BQL 的校验与错误" do
    test "未知字段: the message, the marked word; the results stay", ctx do
      task = task_fixture(ctx.alice.scope, "BOS")
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug, bql: "status = new"))
      assert row_ids(view) == [task.ident]

      type(view, "foo = 1")

      assert has_element?(view, "#query-error-message", "第 1 个字符：unknown field 'foo'")
      assert view |> element("#query-error-preview mark") |> render() =~ ">foo</mark>"

      assert has_element?(
               view,
               ~s(#query-bql[aria-invalid="true"][aria-describedby="query-error-message"])
             )

      assert row_ids(view) == [task.ident]
      refute has_element?(view, "#query-stale")
    end

    test "缺右括号: the position past the end shows a caret", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug))
      type(view, "(status = new")

      assert has_element?(view, "#query-error-message", "第 14 个字符：expected ')'")
      assert has_element?(view, "#query-error-preview [data-caret]")
      refute has_element?(view, "#query-error-preview mark")
    end

    test "改正后错误消失, and validating never runs the query", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug))
      type(view, "foo = 1")
      assert has_element?(view, "#query-error")

      type(view, "status = new")
      refute has_element?(view, "#query-error")
      refute has_element?(view, "#query-error-preview")
      refute has_element?(view, ~s(#query-bql[aria-invalid]))
      refute has_element?(view, "#query-results")
    end

    test "标记以文本显示: markup in the query is escaped", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug))
      html = type(view, "<script>alert(1)</script>")

      assert has_element?(view, "#query-error-preview", "<script>alert(1)</script>")
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html |> LazyHTML.from_document() |> LazyHTML.query("main script") |> Enum.empty?()
      refute html =~ "<script>alert(1)"

      {:ok, view, html} =
        open(ctx.conn, ctx.alice, query_path(ctx.slug, bql: "<script>alert(1)</script>"))

      refute html =~ "<script>alert(1)"
      assert editor(view) == "<script>alert(1)</script>"
      assert has_element?(view, "#query-error-message", "第 1 个字符：expected a field")
    end

    test "a long query is cut around the error", ctx do
      head = String.duplicate("status = new AND ", 6)
      bql = head <> "foo = 1 AND " <> String.duplicate("status = new AND ", 6) <> "status = new"
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug))
      type(view, bql)

      assert has_element?(view, "#query-error-message", "第 103 个字符：unknown field 'foo'")

      text =
        view
        |> element("#query-error-preview")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert String.starts_with?(text, "…")
      assert String.ends_with?(text, "…")
      assert String.length(text) == 82
      assert view |> element("#query-error-preview mark") |> render() =~ ">foo</mark>"
    end

    test "preview/2 counts codepoints" do
      assert %{
               before: "登录 ",
               mark: "foo",
               after: " = 1",
               caret?: false,
               lead?: false,
               trail?: false
             } =
               QueryComponents.preview("登录 foo = 1", 4)

      assert %{before: "(状态", mark: "", caret?: true} = QueryComponents.preview("(状态", 4)
    end

    test "an invalid query run from the URL shows the error and marks old results", ctx do
      task_fixture(ctx.alice.scope, "BOS")
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug, bql: "project = BOS"))

      run(view, "status = ")
      assert_patch(view, query_path(ctx.slug, bql: "status = "))
      assert has_element?(view, "#query-error-message", "第 10 个字符：expected a value")
      assert has_element?(view, "#query-stale")

      run(view, "project = BOS")
      refute has_element?(view, "#query-stale")
      refute has_element?(view, "#query-error")
    end
  end

  describe "BQL 的结果" do
    test "总数与加载更多", ctx do
      for _ <- 1..60, do: task_fixture(ctx.alice.scope, "BOS")
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug))
      run(view, "project = BOS")

      assert length(row_ids(view)) == 50
      assert has_element?(view, "#query-total", "共 60 个任务")
      assert has_element?(view, "#query-order", "按 updated 降序")

      view |> element("#query-tasks-more") |> render_click()
      assert length(Enum.uniq(row_ids(view))) == 60
      refute has_element?(view, "#query-tasks-more")
    end

    test "rows link to the task and show the project, status and assignee", ctx do
      task = task_fixture(ctx.alice.scope, "BOS", %{assignee: ctx.bob.scope.actor.name})
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug, bql: "project = BOS"))

      row = view |> element("#query-task-#{task.ident}") |> render()
      assert row =~ ~s(href="/w/#{ctx.slug}/t/#{task.ident}")
      assert row =~ "BOS"
      assert row =~ ctx.bob.scope.actor.name
    end

    test "相关度排序", ctx do
      task_fixture(ctx.alice.scope, "BOS", %{title: "修复登录问题"})
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug))
      run(view, "text ~ 登录")
      assert has_element?(view, "#query-order", "按相关度")
    end

    test "其他工作区: only the workspace's tasks", ctx do
      other = user_fixture()
      other_ws = workspace_fixture(other)
      other_scope = workspace_scope_fixture(other, other_ws)
      project_fixture(other_scope, key: "OTHER")
      task_fixture(other_scope, "OTHER")

      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug))
      run(view, "project = OTHER")

      assert has_element?(view, "#query-empty", "没有符合条件的任务")
      assert has_element?(view, "#query-total", "共 0 个任务")
    end

    test "加载更多 stops at offset 10000 with a note" do
      assert QueryLive.has_more?(%{loaded: 50, total: 60})
      refute QueryLive.has_more?(%{loaded: 60, total: 60})
      assert QueryLive.has_more?(%{loaded: 9_950, total: 20_000})
      refute QueryLive.has_more?(%{loaded: 10_000, total: 20_000})
      refute QueryLive.capped?(%{loaded: 9_950, total: 20_000})
      assert QueryLive.capped?(%{loaded: 10_000, total: 20_000})
      refute QueryLive.capped?(%{loaded: 10_000, total: 10_000})
    end

    # tasks.md 5.3: a real end-to-end query over agents and runs.
    test "assignee_kind = agent AND run = failed: agent tasks whose latest run failed", ctx do
      %{alice: alice, ws: ws} = ctx
      managed_agent_fixture(alice.scope, %{name: "keel/dev"})
      agent = agent_actor(ws, "keel/dev")

      failed = task_fixture(alice.scope, "BOS", %{assignee: "keel/dev"})
      recovered = task_fixture(alice.scope, "BOS", %{assignee: "keel/dev"})
      human = task_fixture(alice.scope, "BOS", %{assignee: alice.scope.actor.name})
      task_fixture(alice.scope, "BOS", %{assignee: "keel/dev"})

      run_fixture(agent, %{task_id: failed.id, status: :failed})
      run_fixture(agent, %{task_id: recovered.id, status: :failed})
      run_fixture(agent, %{task_id: recovered.id, status: :succeeded})
      run_fixture(agent, %{task_id: human.id, status: :failed})

      bql = "assignee_kind = agent AND run = failed"
      {:ok, view, _html} = open(ctx.conn, alice, query_path(ctx.slug, bql: bql))

      assert row_ids(view) == [failed.ident]
      assert has_element?(view, "#query-total", "共 1 个任务")
    end
  end

  describe "保存的筛选器" do
    test "另存为筛选器", %{conn: conn, slug: slug, alice: alice} do
      {:ok, view, _html} = open(conn, alice, query_path(slug))
      assert has_element?(view, "#query-save-new[aria-disabled]")

      run(view, "status = new")
      view |> element("#query-save-new") |> render_click()
      assert_patch(view, query_path(slug, bql: "status = new", panel: "save-filter"))
      assert open?(view, "filter-form-panel")
      assert in_portal?(view, "filter-form-panel", "#filter-form-sharing", "所有者与管理员可以修改")

      render_submit(view, "filter_form_submit", %{
        filter: %{name: "我的新任务", visibility: "private"}
      })

      [filter] =
        Repo.all(from(f in SavedFilter, where: f.workspace_id == ^alice.scope.workspace.id))

      assert filter.bql == "status = new"
      assert filter.visibility == :private

      assert_patch(view, query_path(slug, filter: filter.id))
      refute open?(view, "filter-form-panel")
      assert has_element?(view, "header h1", "我的新任务")
      assert has_element?(view, "#hm-nav-filters a[href$='?filter=#{filter.id}']", "我的新任务")
      refute has_element?(view, "#query-filter-shared")
      refute has_element?(view, "#query-filter-modified")
    end

    test "a name error stays in the panel", %{conn: conn, slug: slug, alice: alice} do
      {:ok, view, _html} =
        open(conn, alice, query_path(slug, bql: "status = new", panel: "save-filter"))

      render_submit(view, "filter_form_submit", %{
        filter: %{name: String.duplicate("x", 81), visibility: "workspace"}
      })

      assert open?(view, "filter-form-panel")
      assert in_portal?(view, "filter-form-panel", "#filter-form", "长度须为 1–80 个字符")
      assert Repo.aggregate(SavedFilter, :count) == 0
    end

    test "修改后保存", %{conn: conn, slug: slug, alice: alice} do
      filter = create_filter(alice, "我的新任务", "status = new", :private)
      {:ok, view, _html} = open(conn, alice, query_path(slug, filter: filter.id))
      assert editor(view) == "status = new"
      assert has_element?(view, "#query-results")
      refute has_element?(view, "#query-save-to")

      type(view, "status = done")
      assert has_element?(view, "#query-filter-modified", "已修改")
      assert has_element?(view, "#query-save-to", "保存到 我的新任务")
      assert has_element?(view, "#query-save-as", "另存为…")

      view |> element("#query-save-to") |> render_click()
      refute has_element?(view, "#query-filter-modified")
      refute has_element?(view, "#query-save-to")
      assert stored(filter.id).bql == "status = done"

      {:ok, view, _html} = open(conn, alice, query_path(slug, filter: filter.id))
      assert editor(view) == "status = done"
    end

    test "the user's own text is kept, never the canonical form; invalid saves show the error",
         %{conn: conn, slug: slug, alice: alice} do
      filter = create_filter(alice, "f", "status = new", :private)
      {:ok, view, _html} = open(conn, alice, query_path(slug, filter: filter.id))

      type(view, "Status  =  Done  and project=BOS")
      view |> element("#query-save-to") |> render_click()
      assert stored(filter.id).bql == "Status  =  Done  and project=BOS"
      assert editor(view) == "Status  =  Done  and project=BOS"

      type(view, "status = ")
      view |> element("#query-save-to") |> render_click()
      assert has_element?(view, "#query-error-message", "第 10 个字符：expected a value")
      refute has_element?(view, "#query-error-message", "(position")
      assert stored(filter.id).bql == "Status  =  Done  and project=BOS"
    end

    test "a modified query run with a filter keeps both in the URL", ctx do
      filter = create_filter(ctx.alice, "f", "status = new", :private)
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug, filter: filter.id))

      run(view, "status = done")
      assert_patch(view, query_path(ctx.slug, bql: "status = done", filter: filter.id))
      assert has_element?(view, "#query-filter-modified")

      {:ok, view, _html} =
        open(ctx.conn, ctx.alice, query_path(ctx.slug, bql: "status = done", filter: filter.id))

      assert editor(view) == "status = done"
      assert has_element?(view, "#query-filter-modified")
    end

    test "别人的共享筛选器: only 另存为…", %{conn: conn, slug: slug, alice: alice, bob: bob} do
      filter = create_filter(alice, "待合并", "status = new", :workspace)
      {:ok, view, _html} = open(conn, bob, query_path(slug, filter: filter.id))

      assert has_element?(view, "#query-filter-shared", "共享")
      assert has_element?(view, "#query-filter-owner", "所有者：Alice")

      type(view, "status = done")
      assert has_element?(view, "#query-filter-modified")
      assert has_element?(view, "#query-save-as")
      refute has_element?(view, "#query-save-to")
      refute has_element?(view, "#query-filter-menu-trigger")

      render_patch(view, query_path(slug, filter: filter.id, panel: "edit-filter"))
      refute open?(view, "filter-form-panel")
    end

    test "admin 不能改可见性: carol renames, the visibility is read-only", ctx do
      %{conn: conn, slug: slug, alice: alice, carol: carol} = ctx
      filter = create_filter(alice, "待合并", "status = new", :workspace)

      {:ok, view, _html} = open(conn, carol, query_path(slug, filter: filter.id))
      assert has_element?(view, "#query-filter-menu-trigger")

      render_patch(view, query_path(slug, filter: filter.id, panel: "edit-filter"))
      assert open?(view, "filter-form-panel")
      assert in_portal?(view, "filter-form-panel", "#filter-form-name")
      refute in_portal?(view, "filter-form-panel", "input[type=radio]")

      assert in_portal?(
               view,
               "filter-form-panel",
               "#filter-form-visibility-readonly",
               "只有所有者能改变可见性"
             )

      render_submit(view, "filter_form_submit", %{
        filter: %{name: "待合并（新）", visibility: "private"}
      })

      assert_patch(view, query_path(slug, filter: filter.id))
      assert stored(filter.id).name == "待合并（新）"
      assert stored(filter.id).visibility == :workspace
      assert has_element?(view, "header h1", "待合并（新）")
    end

    test "the owner changes the visibility", %{conn: conn, slug: slug, alice: alice} do
      filter = create_filter(alice, "f", "status = new", :private)

      {:ok, view, _html} =
        open(conn, alice, query_path(slug, filter: filter.id, panel: "edit-filter"))

      assert in_portal?(view, "filter-form-panel", "input[type=radio][value=workspace]")
      render_submit(view, "filter_form_submit", %{filter: %{name: "f", visibility: "workspace"}})
      assert stored(filter.id).visibility == :workspace
      assert has_element?(view, "#query-filter-shared")
    end

    test "别人的私有筛选器: not found, the parameter is cleared", ctx do
      filter = create_filter(ctx.alice, "私有", "status = new", :private)
      conn = log_in_user(ctx.conn, ctx.bob.user)

      {:ok, view, html} =
        conn
        |> live(query_path(ctx.slug, filter: filter.id))
        |> follow_redirect(conn)

      assert html =~ "筛选器不存在或你无权查看"
      assert editor(view) == ""
      refute has_element?(view, "#query-results")
    end

    test "an unknown filter id is not found either", ctx do
      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug))
      render_patch(view, query_path(ctx.slug, filter: "999"))
      assert_patch(view, query_path(ctx.slug))
      assert render(view) =~ "筛选器不存在或你无权查看"
    end

    test "viewer: the query and results, no save, edit or delete", ctx do
      task = task_fixture(ctx.alice.scope, "BOS")
      filter = create_filter(ctx.alice, "待合并", "status = new", :workspace)
      {:ok, view, _html} = open(ctx.conn, ctx.vic, query_path(ctx.slug, filter: filter.id))

      assert editor(view) == "status = new"
      assert row_ids(view) == [task.ident]

      type(view, "status = done")

      for id <- ~w(#query-save-to #query-save-as #query-save-new #query-filter-menu-trigger) do
        refute has_element?(view, id)
      end

      render_patch(view, query_path(ctx.slug, filter: filter.id, panel: "save-filter"))
      refute has_element?(view, "#filter-form-panel-portal")
      assert render_click(view, "save_to", %{}) && stored(filter.id).bql == "status = new"
    end

    test "编辑时他人修改: the edit is kept, saving is a conflict, 载入最新 then save", ctx do
      %{conn: conn, slug: slug, alice: alice, carol: carol} = ctx
      filter = create_filter(alice, "待合并", "status = new", :workspace)
      path = query_path(slug, filter: filter.id)

      {:ok, alice_view, _html} = open(conn, alice, path)
      type(alice_view, "pr = open")

      {:ok, carol_view, _html} = open(conn, carol, path)
      type(carol_view, "pr = merged")
      carol_view |> element("#query-save-to") |> render_click()
      assert stored(filter.id).bql == "pr = merged"

      assert has_element?(alice_view, "#query-conflict", "这个筛选器已被他人修改")
      assert editor(alice_view) == "pr = open"

      alice_view |> element("#query-save-to") |> render_click()
      assert has_element?(alice_view, "#query-conflict", "这个筛选器刚被修改")
      assert editor(alice_view) == "pr = open"
      assert stored(filter.id).bql == "pr = merged"

      alice_view |> element("#query-load-latest") |> render_click()
      assert editor(alice_view) == "pr = merged"
      refute has_element?(alice_view, "#query-conflict")
      refute has_element?(alice_view, "#query-filter-modified")

      type(alice_view, "status = new AND project = BOS")
      alice_view |> element("#query-save-to") |> render_click()
      assert stored(filter.id).bql == "status = new AND project = BOS"
      refute has_element?(alice_view, "#query-conflict")
    end

    test "未修改时安静载入", %{conn: conn, slug: slug, alice: alice, carol: carol} do
      task = task_fixture(alice.scope, "BOS")
      filter = create_filter(alice, "待合并", "project = BOS", :workspace)
      {:ok, view, _html} = open(conn, alice, query_path(slug, filter: filter.id))
      assert row_ids(view) == [task.ident]

      {:ok, _} = Filters.update(carol.scope, filter.id, %{bql: "pr = merged", lock_version: 1})

      assert editor(view) == "pr = merged"
      refute has_element?(view, "#query-conflict")
      refute has_element?(view, "#query-filter-modified")
      assert has_element?(view, "#query-total", "共 0 个任务")
    end

    test "an open edit panel keeps the base: the remote change is offered, saving is stale",
         %{conn: conn, slug: slug, alice: alice, carol: carol} do
      filter = create_filter(alice, "待合并", "status = new", :workspace)

      {:ok, view, _html} =
        open(conn, alice, query_path(slug, filter: filter.id, panel: "edit-filter"))

      render_change(view, "filter_form_change", %{filter: %{name: "改名", visibility: "workspace"}})
      {:ok, _} = Filters.update(carol.scope, filter.id, %{bql: "pr = merged", lock_version: 1})

      assert has_element?(view, "#query-conflict", "这个筛选器已被他人修改")
      assert editor(view) == "status = new"

      render_submit(view, "filter_form_submit", %{filter: %{name: "改名", visibility: "workspace"}})
      assert in_portal?(view, "filter-form-panel", "#filter-form-error", "这个筛选器刚被修改")
      assert in_portal?(view, "filter-form-panel", "#filter-form-load-latest", "载入最新")
      assert stored(filter.id).name == "待合并"

      render_click(view, "load_latest", %{})
      assert_patch(view, query_path(slug, filter: filter.id, panel: "edit-filter"))
      assert editor(view) == "pr = merged"
      refute in_portal?(view, "filter-form-panel", "#filter-form-error")

      render_submit(view, "filter_form_submit", %{filter: %{name: "改名", visibility: "workspace"}})
      assert stored(filter.id).name == "改名"
      assert stored(filter.id).bql == "pr = merged"
    end

    test "当前筛选器被删除: unlinked, the editor and results stay", ctx do
      %{conn: conn, slug: slug, alice: alice, bob: bob} = ctx
      task = task_fixture(alice.scope, "BOS")
      filter = create_filter(alice, "待合并", "status = new", :workspace)

      {:ok, view, _html} = open(conn, bob, query_path(slug, filter: filter.id))
      assert row_ids(view) == [task.ident]
      type(view, "status = new AND project = BOS")

      {:ok, _} = Filters.delete(alice.scope, filter.id)

      assert_patch(view, query_path(slug, bql: "status = new AND project = BOS"))
      assert render(view) =~ "筛选器已被删除或你已无权查看"
      assert editor(view) == "status = new AND project = BOS"
      assert row_ids(view) == [task.ident]
      assert has_element?(view, "#query-save-new")
      refute has_element?(view, "#query-save-as")
      refute has_element?(view, "#query-filter-modified")
      refute has_element?(view, "#hm-nav-filters a[href$='?filter=#{filter.id}']")
    end

    test "a filter made private is unlinked for others", ctx do
      %{conn: conn, slug: slug, alice: alice, bob: bob} = ctx
      filter = create_filter(alice, "待合并", "status = new", :workspace)
      {:ok, view, _html} = open(conn, bob, query_path(slug, filter: filter.id))

      {:ok, _} = Filters.update(alice.scope, filter.id, %{visibility: :private})

      assert_patch(view, query_path(slug, bql: "status = new"))
      assert render(view) =~ "筛选器已被删除或你已无权查看"
      assert editor(view) == "status = new"
    end

    test "changes to other filters do not disturb the open one", ctx do
      %{conn: conn, slug: slug, alice: alice, carol: carol} = ctx
      filter = create_filter(alice, "待合并", "status = new", :workspace)
      other = create_filter(carol, "其他", "status = done", :workspace)
      {:ok, view, _html} = open(conn, alice, query_path(slug, filter: filter.id))
      type(view, "pr = open")

      {:ok, _} = Filters.update(carol.scope, other.id, %{bql: "pr = merged"})
      create_filter(carol, "新的", "status = new", :workspace)

      assert has_element?(view, "#hm-nav-filters", "新的")
      refute has_element?(view, "#query-conflict")
      assert editor(view) == "pr = open"
      assert has_element?(view, "#query-filter-modified")
    end

    test "删除: after confirming, the parameter goes and the query stays", ctx do
      %{conn: conn, slug: slug, alice: alice} = ctx
      filter = create_filter(alice, "我的新任务", "status = new", :private)
      {:ok, view, _html} = open(conn, alice, query_path(slug, filter: filter.id))
      assert has_element?(view, "#hm-nav-filters a", "我的新任务")

      view |> element("#query-filter-menu-delete") |> render_click()
      assert open?(view, "delete-filter-dialog")
      assert in_portal?(view, "delete-filter-dialog", "h2", "删除筛选器 我的新任务？")

      render_click(view, "delete", %{})
      assert_patch(view, query_path(slug, bql: "status = new"))
      assert editor(view) == "status = new"
      assert stored(filter.id) == nil
      refute has_element?(view, "#hm-nav-filters a", "我的新任务")
      refute has_element?(view, "header h1", "我的新任务")
    end

    test "a filter whose query no longer parses shows the error and does not run", ctx do
      filter = create_filter(ctx.alice, "坏的", "status = new", :private)
      break_filter(filter)

      {:ok, view, _html} = open(ctx.conn, ctx.alice, query_path(ctx.slug, filter: filter.id))
      assert editor(view) == "foo = 1"
      assert has_element?(view, "#query-error-message", "第 1 个字符：unknown field 'foo'")
      refute has_element?(view, "#query-results")
    end

    test "所有者已离开 is shown on shared filters", ctx do
      filter = create_filter(ctx.bob, "遗留", "status = new", :workspace)
      {:ok, _} = Members.remove(ctx.alice.scope, ctx.bob.membership.id)

      {:ok, view, _html} = open(ctx.conn, ctx.carol, query_path(ctx.slug, filter: filter.id))
      assert has_element?(view, "#query-filter-owner-left", "所有者已离开")
      assert has_element?(view, ~s(#hm-nav-filters a[title="遗留（所有者已离开）"]))
      assert has_element?(view, "#query-filter-menu-trigger")
    end

    test "全部筛选器: grouped, sorted, filtered by name, invalid ones marked", ctx do
      %{conn: conn, slug: slug, alice: alice, bob: bob} = ctx
      b = create_filter(bob, "b 周报", "status = new", :private)
      a = create_filter(bob, "a 待办", "status = new", :workspace)
      shared = create_filter(alice, "待合并", "status = new", :workspace)
      create_filter(alice, "alice 私有", "status = new", :private)
      break_filter(b)

      {:ok, view, _html} = open(conn, bob, query_path(slug))
      view |> element("#query-all-filters") |> render_click()
      assert_patch(view, query_path(slug, panel: "filters"))
      assert open?(view, "filters-panel")

      names = fn group ->
        view
        |> portal("filters-panel")
        |> LazyHTML.query("##{group} [data-name]")
        |> Enum.map(&LazyHTML.text/1)
      end

      assert names.("filters-panel-mine") == ["a 待办", "b 周报"]
      assert names.("filters-panel-shared") == ["待合并"]

      assert in_portal?(
               view,
               "filters-panel",
               "#filters-panel-mine-#{b.id} [data-invalid]",
               "BQL 无效"
             )

      refute in_portal?(view, "filters-panel", "#filters-panel-mine-#{a.id} [data-invalid]")

      assert in_portal?(
               view,
               "filters-panel",
               "#filters-panel-shared-#{shared.id} [data-owner]",
               "Alice"
             )

      render_change(view, "filter_list", %{"q" => "周"})
      assert names.("filters-panel-mine") == ["b 周报"]
      assert names.("filters-panel-shared") == []

      assert portal_attr(view, "filters-panel", "#filters-panel-mine-#{b.id}", "href") ==
               query_path(slug, filter: b.id)
    end
  end
end
