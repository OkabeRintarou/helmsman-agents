defmodule HelmsmanWeb.Markdown.MentionsTest do
  use HelmsmanWeb.MarkdownCase, async: true

  @long String.duplicate("a", 64)

  defp mentions(html) do
    spans = html |> parse() |> LazyHTML.query("span.hm-mention")
    Enum.zip(LazyHTML.attribute(spans, "data-actor"), Enum.map(spans, &LazyHTML.text/1))
  end

  describe "the spec scenarios" do
    test "a mention on the list is marked", %{scope: scope} do
      html = render("@keel/dev 请看", scope, mentions: ["keel/dev"])
      assert mentions(html) == [{"keel/dev", "@keel/dev"}]
      assert html =~ "</span> 请看"
    end

    test "with an empty list @ stays text", %{scope: scope} do
      html = render("@keel/dev 请看", scope, mentions: [])
      assert html == "<p>@keel/dev 请看</p>"
      assert render("@keel/dev 请看", scope) == html
    end
  end

  test "names off the list stay text", %{scope: scope} do
    assert mentions(render("@alice 与 @keel/dev", scope, mentions: ["keel/dev"])) ==
             [{"keel/dev", "@keel/dev"}]
  end

  test "mentions in code and links are not marked", %{scope: scope} do
    html =
      render("`@keel/dev`\n\n```\n@keel/dev\n```\n\n[@keel/dev](https://x.example)", scope,
        mentions: ["keel/dev"]
      )

    assert mentions(html) == []
  end

  test "any case, trailing punctuation dropped, canonical name shown", %{scope: scope} do
    html = render("@KEEL/DEV. 和 @Keel/Dev/", scope, mentions: ["keel/dev"])
    assert mentions(html) == [{"keel/dev", "@keel/dev"}, {"keel/dev", "@keel/dev"}]
    assert html =~ "</span>. 和"
    assert html =~ "</span>/</p>"
  end

  test "never a prefix of a longer name", %{scope: scope} do
    assert mentions(
             render("@#{@long}a @keel/devx a@keel/dev", scope, mentions: [@long, "keel/dev"])
           ) == []

    assert mentions(render("@#{@long}.", scope, mentions: [@long])) == [{@long, "@" <> @long}]
  end

  test "a mention next to a reference keeps both", %{scope: scope} do
    html = render("@keel/dev #NOPE-1", scope, mentions: ["keel/dev"])
    assert mentions(html) == [{"keel/dev", "@keel/dev"}]
    assert html =~ "#NOPE-1"
  end

  # add-collaboration-ui D9: mentions that triggered nothing.
  describe "muted mentions" do
    test "a muted mention carries data-skipped and its reason", %{scope: scope} do
      html =
        render("@keel/c 与 @keel/dev", scope,
          mentions: ["keel/c", "keel/dev"],
          muted_mentions: %{"keel/c" => "触发者无权触发它"}
        )

      spans = html |> parse() |> LazyHTML.query("span.hm-mention[data-skipped]")
      assert LazyHTML.attribute(spans, "data-actor") == ["keel/c"]
      assert LazyHTML.attribute(spans, "title") == ["触发者无权触发它"]
      assert mentions(html) == [{"keel/c", "@keel/c"}, {"keel/dev", "@keel/dev"}]
    end

    test "the reason is escaped", %{scope: scope} do
      html =
        render("@keel/c", scope,
          mentions: ["keel/c"],
          muted_mentions: %{"keel/c" => ~s(<b>"x"</b>)}
        )

      refute html =~ "<b>"
      spans = html |> parse() |> LazyHTML.query("span.hm-mention")
      assert LazyHTML.attribute(spans, "title") == [~s(<b>"x"</b>)]
    end

    test "user markup cannot fake a skipped mention", %{scope: scope} do
      html = render(~s(<span class="hm-mention" data-skipped="true" title="x">@a</span>), scope)
      assert html |> parse() |> LazyHTML.query("span[data-skipped]") |> Enum.count() == 0
    end
  end
end
