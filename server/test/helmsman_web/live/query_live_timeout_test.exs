defmodule HelmsmanWeb.QueryLiveTimeoutTest do
  @moduledoc """
  Query timeouts on the BQL page (spec web-query BQL 的校验与错误, code-review-1 P2-2).
  The statement timeout of `Helmsman.BQL` is application config, so this module is not
  async; the executor's test hook (`:helmsman_bql_query_hook`) runs a slow statement in
  the LiveView process.
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  setup %{conn: conn} do
    previous = Application.get_env(:helmsman, Helmsman.BQL)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:helmsman, Helmsman.BQL, previous),
        else: Application.delete_env(:helmsman, Helmsman.BQL)
    end)

    alice = user_fixture(%{display_name: "Alice"})
    ws = workspace_fixture(alice)
    scope = workspace_scope_fixture(alice, ws)
    project_fixture(scope, key: "BOS", name: "Bosun")

    %{conn: log_in_user(conn, alice), slug: ws.slug, scope: scope, previous: previous}
  end

  defp query_path(slug, bql), do: "/w/#{slug}/query?" <> URI.encode_query(bql: bql)

  defp run(view, bql), do: view |> form("#query-form", query: %{bql: bql}) |> render_submit()

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#query-tasks tr[id^=query-task-]")
    |> LazyHTML.attribute("id")
  end

  # Every query of the LiveView times out while `fun` runs.
  defp timing_out(view, previous, fun) do
    Application.put_env(:helmsman, Helmsman.BQL, statement_timeout_ms: 100)
    put_hook(view, fn -> Helmsman.Repo.query!("SELECT pg_sleep(1)") end)

    try do
      fun.()
    after
      put_hook(view, nil)

      if previous,
        do: Application.put_env(:helmsman, Helmsman.BQL, previous),
        else: Application.delete_env(:helmsman, Helmsman.BQL)
    end
  end

  defp put_hook(view, hook) do
    :sys.replace_state(view.pid, fn state ->
      if hook,
        do: Process.put(:helmsman_bql_query_hook, hook),
        else: Process.delete(:helmsman_bql_query_hook)

      state
    end)
  end

  test "a timeout keeps the last results and marks them 已过期", ctx do
    task = task_fixture(ctx.scope, "BOS")
    {:ok, view, _html} = live(ctx.conn, query_path(ctx.slug, "project = BOS"))
    assert row_ids(view) == ["query-task-#{task.ident}"]

    timing_out(view, ctx.previous, fn -> view |> element("#query-rerun") |> render_click() end)

    assert has_element?(
             view,
             "#query-error-message",
             "查询超时：请缩小范围（例如加上 project = KEY）"
           )

    refute has_element?(view, "#query-error-preview")
    assert has_element?(view, "#query-stale", "已过期")
    assert row_ids(view) == ["query-task-#{task.ident}"]

    view |> element("#query-rerun") |> render_click()
    refute has_element?(view, "#query-stale")
    refute has_element?(view, "#query-error")
  end

  # code-review-1 P2-2: after a failed run, 加载更多 continues the rows shown.
  test "a failed new query: 加载更多 continues the old query, no mixed rows", ctx do
    for _ <- 1..60, do: task_fixture(ctx.scope, "BOS")
    {:ok, view, _html} = live(ctx.conn, query_path(ctx.slug, "project = BOS"))
    first = row_ids(view)
    assert length(first) == 50

    # The new query matches nothing: paging it from offset 50 would add no rows.
    timing_out(view, ctx.previous, fn -> run(view, "status = done") end)
    assert_patch(view, query_path(ctx.slug, "status = done"))
    assert has_element?(view, "#query-error-message", "查询超时")
    assert has_element?(view, "#query-stale")

    view |> element("#query-tasks-more") |> render_click()
    assert length(Enum.uniq(row_ids(view))) == 60
    assert Enum.take(row_ids(view), 50) == first
    refute has_element?(view, "#query-tasks-more")

    run(view, "project = BOS")
    refute has_element?(view, "#query-stale")
    assert has_element?(view, "#query-total", "共 60 个任务")
  end
end
