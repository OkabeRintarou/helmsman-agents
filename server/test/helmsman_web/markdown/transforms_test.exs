defmodule HelmsmanWeb.Markdown.TransformsTest do
  use HelmsmanWeb.MarkdownCase, async: true

  defp links(html) do
    html
    |> parse()
    |> LazyHTML.query("a")
    |> Enum.map(&{&1 |> LazyHTML.attribute("href") |> List.first(), LazyHTML.text(&1)})
  end

  describe "images render as links" do
    test "the alt text links to the image address", %{scope: scope} do
      html = render("![架构图](https://example.com/a.png)", scope)

      assert count(html, "img") == 0
      assert attrs(html, "a", "href") == ["https://example.com/a.png"]
      assert html |> parse() |> LazyHTML.query("a") |> LazyHTML.text() == "架构图"
    end

    test "without alt text the address is shown", %{scope: scope} do
      html = render("![](https://example.com/b.png)", scope)

      assert html |> parse() |> LazyHTML.query("a") |> LazyHTML.text() ==
               "https://example.com/b.png"
    end

    test "a linked image keeps its alt text and its address, links never nest",
         %{scope: scope} do
      html = render("[![架构图](https://example.com/image.png)](https://example.com/page)", scope)

      assert count(html, "img") == 0
      assert count(html, "a a") == 0

      assert links(html) == [
               {"https://example.com/page", "架构图"},
               {"https://example.com/image.png", "https://example.com/image.png"}
             ]
    end

    test "a linked image without alt text", %{scope: scope} do
      html = render("[![](https://example.com/i.png)](https://example.com/page)", scope)

      assert links(html) == [
               {"https://example.com/page", "https://example.com/page"},
               {"https://example.com/i.png", "https://example.com/i.png"}
             ]
    end

    test "images and links in alt text", %{scope: scope} do
      html =
        render(
          "![outer ![inner](https://example.com/inner.png) [l](https://l.example)](https://example.com/outer.png)",
          scope
        )

      assert count(html, "img") == 0
      assert count(html, "a a") == 0

      assert links(html) == [
               {"https://example.com/outer.png", "outer inner l"},
               {"https://example.com/inner.png", "https://example.com/inner.png"}
             ]
    end

    test "a linked image with an unsafe address is no link", %{scope: scope} do
      html = render("[![x](javascript:alert(1))](https://example.com/page)", scope)

      assert count(html, "img") == 0
      assert [{"https://example.com/page", "x"}, {href, _}] = links(html)
      refute href =~ "javascript"
    end

    test "an unsafe address is no link", %{scope: scope} do
      html = render("![x](javascript:alert(1)) ![y](data:image/png;base64,AAAA)", scope)

      assert count(html, "img") == 0
      for href <- attrs(html, "a", "href"), do: assert(href == "")
    end
  end

  describe "code highlighting" do
    test "an Elixir block gets highlight classes, no style", %{scope: scope} do
      html = render("```elixir\ndefmodule A, do: :ok\n```\n", scope)

      assert count(html, "pre code.language-elixir") == 1
      assert count(html, "pre code span[class^=\"l-\"]") > 1
      refute html =~ "style="

      assert html |> parse() |> LazyHTML.query("code") |> LazyHTML.text() ==
               "defmodule A, do: :ok"
    end

    test "an unknown language is plain, escaped text", %{scope: scope} do
      html = render("```nosuchlang\nx <y> & z\n```\n", scope)

      assert count(html, "pre code span[class^=\"l-\"]:not(.l-line)") == 0
      assert html =~ "x &lt;y&gt; &amp; z"
      refute html =~ "style="
    end
  end

  describe "mermaid placeholders" do
    test "the source is kept, escaped, in a marked element", %{scope: scope} do
      html = render("```mermaid\ngraph TD; A-->B\n```\n", scope)

      assert [_] = attrs(html, "pre[data-mermaid]", "data-mermaid")
      assert html =~ "graph TD; A--&gt;B"

      assert html |> parse() |> LazyHTML.query("pre[data-mermaid] code") |> LazyHTML.text() ==
               "graph TD; A-->B\n"

      assert count(html, "pre[data-mermaid] span") == 0
    end

    test "markup in the source stays text", %{scope: scope} do
      html = render("```mermaid\ngraph TD; A[\"<script>alert(1)</script>\"]-->B\n```\n", scope)

      assert count(html, "script") == 0
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end
  end
end
