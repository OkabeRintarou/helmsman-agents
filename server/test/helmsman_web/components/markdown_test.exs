defmodule HelmsmanWeb.Components.MarkdownTest do
  use HelmsmanWeb.MarkdownCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import HelmsmanWeb.Components.Markdown

  defp html(content, scope, opts \\ []) do
    assigns = %{
      content: content,
      scope: scope,
      ns: opts[:ns] || "desc",
      mentions: opts[:mentions] || []
    }

    rendered_to_string(~H"""
    <.markdown content={@content} scope={@scope} anchor_ns={@ns} mentions={@mentions} class="x-extra" />
    """)
  end

  test "the container carries the namespace, a content hash and the Mermaid hook", %{scope: scope} do
    out = html("**hi**", scope)
    [id] = attrs(out, "div.hm-prose", "id")

    assert id == "md-desc-#{:erlang.phash2("**hi**")}"
    assert id == dom_id("desc", "**hi**")
    assert attrs(out, "div.hm-prose", "phx-hook") == ["Mermaid"]
    assert attrs(out, "div.hm-prose", "phx-update") == ["ignore"]

    assert attrs(out, "div.hm-prose", "data-mermaid-src") |> hd() =~
             ~r{^/assets/js/mermaid(-[0-9a-f]+)?\.js}

    assert attrs(out, "div.hm-prose", "class") == ["hm-prose x-extra"]
    assert count(out, "div.hm-prose strong") == 1
  end

  test "other content or another namespace gives another id", %{scope: scope} do
    [a] = attrs(html("one", scope), "div.hm-prose", "id")
    [b] = attrs(html("two", scope), "div.hm-prose", "id")
    [c] = attrs(html("one", scope, ns: "fb-1"), "div.hm-prose", "id")
    assert length(Enum.uniq([a, b, c])) == 3
    assert c =~ "md-fb-1-"
  end

  test "raw HTML is escaped", %{scope: scope} do
    out = html("<script>alert(1)</script>", scope)
    refute out =~ "<script>"
    assert out =~ "&lt;script&gt;"
  end

  test "mentions and mermaid blocks come through", %{scope: scope} do
    out = html("@keel/dev\n\n```mermaid\ngraph TD; A-->B\n```", scope, mentions: ["keel/dev"])
    assert attrs(out, "span.hm-mention", "data-actor") == ["keel/dev"]
    assert count(out, "pre[data-mermaid]") == 1
  end

  test "markdown.css uses tokens only" do
    css = File.read!(Path.expand("../../../assets/css/markdown.css", __DIR__))
    refute css =~ ~r/#[0-9a-fA-F]{3,8}\b|rgb\(|oklch\(/
    assert css =~ "var(--hm-"
  end
end
