defmodule HelmsmanWeb.Markdown.GfmTest do
  use HelmsmanWeb.MarkdownCase, async: true

  describe "the spec scenarios" do
    test "tables and read-only task lists", %{scope: scope} do
      html = render("| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] 完成\n- [ ] 待办\n", scope)

      assert count(html, "table") == 1
      assert count(html, "td") == 2
      assert count(html, ~s(input[type="checkbox"][disabled])) == 2
      assert count(html, "input[checked]") == 1
      assert html =~ ~r/<input[^>]*checked[^>]*> 完成/
    end

    test "footnotes link to the note in the same output", %{scope: scope} do
      html = render("正文[^1]\n\n[^1]: 说明\n", scope)

      assert [href] = attrs(html, "sup a", "href")
      assert "#" <> id = href
      assert html |> parse() |> LazyHTML.query_by_id(id) |> LazyHTML.text() =~ "说明"
    end
  end

  test "headings, quotes, strikethrough and autolinks", %{scope: scope} do
    html =
      render(
        "# 标题\n\n> 引用\n\n~~删除~~ www.example.com <https://a.example> bob@example.com\n",
        scope
      )

    assert html =~ "<h1>标题</h1>"
    assert html =~ ~r/<blockquote>\s*<p>引用<\/p>\s*<\/blockquote>/
    assert html =~ "<del>删除</del>"

    assert attrs(html, "a", "href") == [
             "http://www.example.com",
             "https://a.example",
             "mailto:bob@example.com"
           ]
  end

  test "paragraphs, lists, inline code and code blocks", %{scope: scope} do
    html = render("段落 `x < y`\n\n1. 一\n2. 二\n\n```\nplain\n```\n", scope)

    assert html =~ "<code>x &lt; y</code>"
    assert count(html, "ol li") == 2
    assert html |> parse() |> LazyHTML.query("pre code") |> LazyHTML.text() == "plain"
  end
end
