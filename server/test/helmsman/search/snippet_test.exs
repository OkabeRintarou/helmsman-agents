defmodule Helmsman.Search.SnippetTest do
  # add-fulltext-search 1.6: snippets (decision 7).
  use ExUnit.Case, async: true

  alias Helmsman.Search.Snippet
  alias Helmsman.Search.Tokenizer

  defp build(text, query), do: Snippet.build(text, Tokenizer.query(query))
  defp html(segments), do: segments |> Snippet.to_html() |> Phoenix.HTML.safe_to_string()

  test "转义: HTML is escaped, then hits are marked" do
    segments = build("<script>alert(1)</script> login failed", "login")
    assert html(segments) == "&lt;script&gt;alert(1)&lt;/script&gt; <mark>login</mark> failed"
  end

  test "& and quotes are escaped too" do
    segments = build(~S(a & "b" 'c' login), "login")
    assert html(segments) == "a &amp; &quot;b&quot; &#39;c&#39; <mark>login</mark>"
  end

  test "长描述: about 40 characters on each side, with ellipses" do
    before = String.duplicate("前", 500)
    after_ = String.duplicate("后", 500)
    segments = build(before <> " login " <> after_, "login")

    assert [%{text: "…" <> left, hit: false}, %{text: "login", hit: true}, %{text: right}] =
             segments

    assert String.length(left) == 40
    assert String.ends_with?(right, "…")
    assert String.length(right) == 41
  end

  test "文本形式: hits in **" do
    segments = build("<b> login failed", "login")
    assert Snippet.to_text(segments) == "<b> **login** failed"
  end

  test "no hit: nil" do
    assert build("nothing here", "login") == nil
    assert build(nil, "login") == nil
    assert build("", "login") == nil
    assert Snippet.build("x", []) == nil
  end

  test "overlapping bigrams are merged into one hit" do
    segments = build("请检查任务管理页面", "任务管理")

    assert segments == [
             %{text: "请检查", hit: false},
             %{text: "任务管理", hit: true},
             %{text: "页面", hit: false}
           ]
  end

  test "every hit in the window is marked; prefixes match" do
    segments = build("deadlock in x, another deadlocked y", "deadl")

    assert Snippet.to_text(segments) == "**deadlock** in x, another **deadlocked** y"
  end

  test "whitespace runs and newlines collapse to one space; the ends are trimmed" do
    segments = build("\n  first\n\n\tlogin   then \n", "login")
    assert Snippet.to_text(segments) == "first **login** then"
  end

  test "cut on grapheme boundaries: emoji and combining characters stay whole" do
    family = "👨‍👩‍👧"
    accented = "e\u0301"
    text = String.duplicate(family, 45) <> " login " <> String.duplicate(accented, 45)
    [%{text: "…" <> left}, %{hit: true}, %{text: right}] = build(text, "login")

    assert String.graphemes(left) == List.duplicate(family, 39) ++ [" "]
    assert right == " " <> String.duplicate(accented, 39) <> "…"
    assert String.valid?(left) and String.valid?(right)
  end

  test "a hit at the very start or end gets no ellipsis on that side" do
    assert [%{text: "login", hit: true}, %{text: " now", hit: false}] =
             build("login now", "login")

    assert [%{text: "now ", hit: false}, %{text: "login", hit: true}] =
             build("now login", "login")
  end

  test "the window starts at the first hit" do
    text = "login " <> String.duplicate("x ", 100) <> "login"
    segments = build(text, "login")
    assert [%{text: "login", hit: true}, %{text: rest, hit: false}] = segments
    assert String.ends_with?(rest, "…")
  end

  test "hit?/2" do
    assert Snippet.hit?("deadlock", [{:prefix, "dead"}])
    assert Snippet.hit?("务管", [{:phrase, ["任务", "务管"]}])
    assert Snippet.hit?("x", [{:term, "x"}])
    refute Snippet.hit?("xy", [{:term, "x"}])
  end
end
