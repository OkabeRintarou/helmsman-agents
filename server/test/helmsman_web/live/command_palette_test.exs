defmodule HelmsmanWeb.CommandPaletteTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HelmsmanWeb.CommandPalette.{Actions, Ident}

  defp palette(view), do: view |> element("#command-palette-dialog-portal") |> render()
  # Same as the Hotkeys hook's pushEventTo("#command-palette", …) in the browser.
  defp palette_event(view, event, params),
    do: view |> with_target("#command-palette") |> render_click(event, params)

  defp search(view, q), do: palette_event(view, "search", %{"q" => q})

  test "KEY-N jumps to the task page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    search(view, "bos-12")

    assert palette(view) =~ "跳转到任务"
    assert palette(view) =~ "BOS-12"

    palette_event(view, "execute", %{})
    assert_redirect(view, "/w/acme/t/BOS-12")
  end

  test "pages matching the query are listed", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    search(view, "项目")
    html = palette(view)

    assert html =~ "页面"
    assert html =~ "查看全部"

    palette_event(view, "execute", %{"index" => "0"})
    assert_redirect(view, "/dev/ui/projects")
  end

  test "no match shows a hint", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    search(view, "zzzz-nothing")
    assert palette(view) =~ "没有匹配的结果"
    palette_event(view, "execute", %{})
    refute_redirected(view)
  end

  test "empty input lists recent tasks and all actions", %{conn: conn} do
    conn = put_connect_params(conn, %{"recent_tasks" => ["BOS-3", "bos-9", "not a task"]})
    {:ok, view, _html} = live(conn, "/dev/ui")
    html = palette(view)

    assert html =~ "最近访问"
    assert html =~ "BOS-3"
    assert html =~ "BOS-9"
    refute html =~ "not a task"
    for label <- ["新建任务", "切换主题：暗", "复制当前页面链接"], do: assert(html =~ label)
  end

  test "the selection is kept on the server and wraps", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")

    assert palette(view) =~
             ~r/id="command-palette-dialog-result-0" role="option" aria-selected="true"/

    palette_event(view, "move", %{"delta" => 1})

    assert palette(view) =~
             ~r/id="command-palette-dialog-result-1" role="option" aria-selected="true"/

    palette_event(view, "move", %{"delta" => -2})

    assert palette(view) =~
             ~r/id="command-palette-dialog-result-4" role="option" aria-selected="true"/
  end

  test "actions run on the client", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    search(view, "新建")
    palette_event(view, "execute", %{})
    assert_push_event(view, "hm:palette-action", %{action: "new-task"})

    search(view, "暗")
    palette_event(view, "execute", %{})
    assert_push_event(view, "hm:palette-action", %{action: "theme", theme: "dark"})
  end

  test "sources" do
    scope = %{workspace: %{slug: "acme"}}
    assert [%{path: "/w/acme/t/ABC-7"}] = Ident.search(scope, " abc-7 ", %{})
    assert Ident.search(scope, "abc", %{}) == []
    assert Ident.search(nil, "abc-1", %{}) == []
  end

  test "ident format follows the task ID rules" do
    for valid <- [
          "BOS-1",
          "bos-12",
          "AB-7",
          "ABCDEFGHIJ-3",
          "A1-9",
          "BOS-1000000000",
          "BOS-2147483647"
        ] do
      assert Ident.parse(valid) == String.upcase(valid), valid
    end

    for invalid <- [
          "B-1",
          "BOS-0",
          "BOS-03",
          "1BOS-1",
          "ABCDEFGHIJK-1",
          "BOS-2147483648",
          "BOS-",
          "BOS 1",
          "BOS-1x"
        ] do
      assert Ident.parse(invalid) == nil, invalid
    end

    scope = %{workspace: %{slug: "acme"}}
    assert [%{path: "/w/acme/t/BOS-1000000000"}] = Ident.search(scope, "bos-1000000000", %{})
    assert Ident.search(scope, "BOS-03", %{}) == []

    assert [%{label: "BOS-2"}] =
             Ident.search(scope, "", %{recent_tasks: ["BOS-0", "bos-2", "B-1"]})

    assert length(Actions.search(scope, "", %{})) == 5
  end
end
