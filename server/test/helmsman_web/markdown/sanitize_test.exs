defmodule HelmsmanWeb.Markdown.SanitizeTest do
  use HelmsmanWeb.MarkdownCase, async: true

  @rel "noopener noreferrer nofollow"

  # Nothing that can run or load: no such elements, no event handlers or
  # styles, no link to a non-http(s)/mailto address.
  defp assert_inert(html) do
    for selector <-
          ~w(script style iframe object embed svg math img form) ++
            [~s{input:not([type="checkbox"])}] do
      assert count(html, selector) == 0, "#{selector} in #{html}"
    end

    tree = parse(html)

    for {_tag, attributes, _children} <- all_elements(LazyHTML.to_tree(tree)),
        {name, value} <- attributes do
      refute String.starts_with?(name, "on"), "#{name} in #{html}"
      refute name in ["style", "src", "action", "formaction", "xlink:href"], "#{name} in #{html}"
      # a dangerous scheme may show as escaped text, never in an attribute
      refute value =~ ~r/(java|vb)script:|data:/i, "#{name}=#{value} in #{html}"

      if name == "href" do
        assert value == "" or value =~ ~r/\A(https?:|mailto:|\/|#)/i, "href=#{value} in #{html}"
      end
    end

    for rel <- attrs(html, "a", "rel"), do: assert(rel == @rel)
    assert length(attrs(html, "a", "rel")) == count(html, "a")
  end

  defp all_elements(nodes) do
    Enum.flat_map(nodes, fn
      {tag, attributes, children} -> [{tag, attributes, children} | all_elements(children)]
      _text -> []
    end)
  end

  describe "the spec scenarios" do
    test "embedded scripts show as escaped text", %{scope: scope} do
      html = render("<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n", scope)

      assert_inert(html)
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    end

    test "dangerous links are not clickable", %{scope: scope} do
      html = render("[点我](javascript:alert(1)) [数据](data:text/html;base64,PHNjcmlwdD4=)", scope)

      assert_inert(html)
      refute html =~ "javascript:"
      refute html =~ "data:"
    end

    test "plain links keep their address and get rel", %{scope: scope} do
      html = render("[文档](https://example.com/doc)", scope)

      assert attrs(html, "a", "href") == ["https://example.com/doc"]
      assert attrs(html, "a", "rel") == [@rel]
    end
  end

  @inputs [
    "<svg onload=alert(1)>",
    ~s{<a href="javascript:alert(1)">x</a>},
    "[x](JaVaScRiPt:alert(1))",
    "[x](vbscript:msgbox)",
    "<iframe src=https://x>",
    "<style>body{}</style>",
    ~s(<div style="x">),
    "<form action=x><input></form>",
    ~s{<math><mi xlink:href="javascript:alert(1)">},
    "[x](&#106;avascript:alert(1))",
    "<!-- <script>alert(1)</script> -->",
    "x <!-- <script>alert(1)</script> --> y",
    ~s(<object data="x.swf"></object>),
    "![x](javascript:alert(1))",
    "<javascript:alert(1)>"
  ]

  for input <- @inputs do
    test "nothing executable in #{inspect(input)}", %{scope: scope} do
      html = render(unquote(input), scope)
      assert_inert(html)
    end
  end

  test "every link carries rel, generated ones included", %{scope: scope} do
    html =
      render(
        "[a](https://a.example) <https://b.example> www.c.example x[^1] ![i](https://d.example/i.png)\n\n[^1]: n\n",
        scope
      )

    assert_inert(html)
    assert count(html, "a") == 6
  end
end
