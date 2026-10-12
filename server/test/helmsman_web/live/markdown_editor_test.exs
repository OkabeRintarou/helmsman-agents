defmodule HelmsmanWeb.MarkdownEditorTest do
  # Drives the demo editor of /dev/ui (session starts at 1, 重新开始 starts a new one).
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HelmsmanWeb.MarkdownEditor

  setup %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    %{view: view}
  end

  defp hook(view, event, params),
    do: view |> with_target("#demo-editor") |> render_hook(event, params)

  defp preview(view, value, session \\ 1),
    do: hook(view, "set_mode", %{"mode" => "preview", "value" => value, "session" => session})

  defp query(view, q, session \\ 1),
    do: hook(view, "mention_query", %{"q" => q, "session" => session})

  defp names(view) do
    view
    |> element("#demo-editor-mentions")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[role=option]")
    |> LazyHTML.attribute("data-name")
  end

  describe "edit and preview" do
    test "the textarea is the only field, kept in the form and the DOM", %{view: view} do
      input = ~s(#demo-md-form #demo-editor-input-1[name=demo_md])
      assert has_element?(view, input <> "[phx-hook=Editor][data-submit=mod-enter-form]")
      assert has_element?(view, input <> "[data-session=\"1\"][data-editor=demo-editor]")
      refute has_element?(view, "#demo-editor-input-1[phx-target]")
      assert has_element?(view, "#demo-editor-source-1[phx-update=ignore] > #demo-editor-input-1")
      assert has_element?(view, ~s(#demo-editor-tab-edit[aria-selected="true"]))

      preview(view, "x")
      assert has_element?(view, "#demo-editor-source.hidden #demo-editor-input-1[name=demo_md]")

      assert render(view)
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("[name=demo_md]")
             |> Enum.count() == 1

      assert has_element?(
               view,
               ~s(#demo-md-form input[type=hidden][name=editor_session][value="1"])
             )
    end

    test "the preview shows the text sent with the switch (刚输入就预览)", %{view: view} do
      preview(view, "**新内容**")

      assert has_element?(view, ~s(#demo-editor-tab-preview[aria-selected="true"]))
      assert has_element?(view, "#demo-editor-preview .hm-prose strong", "新内容")

      [id] =
        view
        |> element("#demo-editor-preview")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".hm-prose")
        |> LazyHTML.attribute("id")

      assert id =~ "md-preview-demo-editor-"

      hook(view, "set_mode", %{"mode" => "edit", "value" => "**新内容**", "session" => 1})
      refute has_element?(view, "#demo-editor-preview")
      refute has_element?(view, "#demo-editor-source.hidden")
    end

    test "an empty preview says so", %{view: view} do
      preview(view, "  \n")
      assert has_element?(view, "#demo-editor-preview", "没有内容")
    end

    test "only candidates are marked as mentions in the preview", %{view: view} do
      preview(view, "@keel/dev 和 @nobody")
      assert has_element?(view, ~s(#demo-editor-preview span.hm-mention[data-actor="keel/dev"]))
      refute has_element?(view, ~s(#demo-editor-preview span.hm-mention[data-actor="nobody"]))
    end

    test "submitting in preview mode sends the textarea", %{view: view} do
      preview(view, "**写好的**")
      view |> form("#demo-md-form", %{demo_md: "**写好的**"}) |> render_submit()
      assert has_element?(view, "#demo-md-submitted", "**写好的**")
    end
  end

  describe "editing sessions" do
    test "a new session replaces the textarea and resets the editor", %{view: view} do
      preview(view, "草稿")
      query(view, "ke")
      assert has_element?(view, "#demo-editor-mentions")

      view |> element("button", "重新开始") |> render_click()

      refute has_element?(view, "#demo-editor-input-1")
      refute has_element?(view, "#demo-editor-source-1")

      assert has_element?(
               view,
               "#demo-editor-source-2 > #demo-editor-input-2[data-session=\"2\"]"
             )

      assert view |> element("#demo-editor-input-2") |> render() =~ ~r/>\s*<\/textarea>/
      assert has_element?(view, ~s(#demo-editor-tab-edit[aria-selected="true"]))
      refute has_element?(view, "#demo-editor-preview")
      refute has_element?(view, "#demo-editor-mentions")

      tab = view |> element("#demo-editor-tab-preview") |> render()
      assert tab =~ "#demo-editor-input-2"
      refute tab =~ "#demo-editor-input-1"
    end

    test "re-rendering in the same session keeps the ids", %{view: view} do
      view |> element("button", "错误提示") |> render_click()
      assert render(view) =~ "操作失败：这是一条错误提示"
      assert has_element?(view, "#demo-editor-input-1")
    end

    test "events of an old session are ignored", %{view: view} do
      view |> element("button", "重新开始") |> render_click()

      preview(view, "旧的", 1)
      refute has_element?(view, "#demo-editor-preview")

      query(view, "ke", 1)
      refute has_element?(view, "#demo-editor-mentions")

      query(view, "ke", 2)
      assert has_element?(view, "#demo-editor-mentions")
      hook(view, "mention_close", %{"session" => 1})
      assert has_element?(view, "#demo-editor-mentions")
    end
  end

  describe "@ completion" do
    test "humans first, then agents (补全 Agent)", %{view: view} do
      query(view, "k")
      assert names(view) == ["kate", "keel/dev", "keel/review"]

      assert has_element?(view, "#demo-editor-input-1[aria-controls=demo-editor-mentions]")

      assert has_element?(
               view,
               "#demo-editor-mentions[role=listbox] > li#demo-editor-mention-0[role=option]"
             )

      assert has_element?(view, ~s(#demo-editor-mention-0[aria-selected="true"]))
    end

    test "matches a / segment (按分段匹配)", %{view: view} do
      query(view, "dev")
      assert names(view) == ["keel/dev"]
      query(view, "REV")
      assert names(view) == ["keel/review"]
    end

    test "no match, no list; mention_close closes it", %{view: view} do
      query(view, "zzz")
      refute has_element?(view, "[role=listbox]")

      query(view, "")
      assert length(names(view)) == 4
      hook(view, "mention_close", %{"session" => 1})
      refute has_element?(view, "#demo-editor-mentions")
    end

    test "at most 8 candidates" do
      many = for i <- 1..12, do: %{name: "a#{String.pad_leading("#{i}", 2, "0")}", kind: "human"}
      assert length(MarkdownEditor.complete(many, "a")) == 8
      assert MarkdownEditor.complete(many, "a") |> hd() |> Map.get(:name) == "a01"
    end
  end
end
