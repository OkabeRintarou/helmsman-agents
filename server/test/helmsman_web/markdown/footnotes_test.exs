defmodule HelmsmanWeb.Markdown.FootnotesTest do
  use HelmsmanWeb.MarkdownCase, async: true
  use ExUnitProperties

  @doc_two "正文[^1]，再看[^2]，又见[^1]。\n\n[^1]: 说明一\n[^2]: 说明二\n"

  defp ids(html), do: attrs(html, "[id]", "id")
  defp fragments(html), do: for("#" <> id <- attrs(html, ~s(a[href^="#"]), "href"), do: id)

  test "every fragment link has its target, both ways, in the namespace", %{scope: scope} do
    html = render(@doc_two, scope, anchor_ns: "desc")
    ids = ids(html)

    # three references and three back links
    assert length(fragments(html)) == 6
    for id <- fragments(html), do: assert(id in ids, "no ##{id} in #{html}")
    for id <- ids, do: assert(id =~ "desc")

    for ref_href <- attrs(html, "sup a", "href") do
      assert "#fn-" <> _ = ref_href
    end

    assert Enum.any?(attrs(html, "li a", "href"), &String.starts_with?(&1, "#fnref-"))
  end

  # Every id is unique, every fragment link has exactly one target, each
  # reference points at a note whose back links include that reference, and
  # each back link points at a reference to its note.
  defp assert_footnotes_consistent(html) do
    tree = parse(html)
    ids = ids(html)
    assert length(ids) == length(Enum.uniq(ids)), "duplicate ids in #{html}"

    refs = LazyHTML.query(tree, "sup a[id]")

    for ref <- refs do
      [ref_id] = LazyHTML.attribute(ref, "id")
      ["#" <> note_id] = LazyHTML.attribute(ref, "href")
      note = LazyHTML.query_by_id(tree, note_id)
      assert Enum.count(note) == 1
      assert ("#" <> ref_id) in (note |> LazyHTML.query("a") |> LazyHTML.attribute("href"))
    end

    for note <- LazyHTML.query(tree, "section li[id]"),
        "#" <> ref_id <- note |> LazyHTML.query("a") |> LazyHTML.attribute("href") do
      [note_id] = LazyHTML.attribute(note, "id")
      ref = LazyHTML.query_by_id(tree, ref_id)
      assert Enum.count(ref) == 1
      assert LazyHTML.attribute(ref, "href") == ["#" <> note_id]
    end
  end

  test "a repeated reference and a note named like its id stay apart", %{scope: scope} do
    html = render("正文[^x]\n\n[^x]: first\n\n正文[^x]\n\n正文[^x-2]\n\n[^x-2]: second\n", scope)
    assert_footnotes_consistent(html)
    assert count(html, "sup a") == 3

    tree = parse(html)
    [ref] = tree |> LazyHTML.query("sup a") |> Enum.at(2) |> LazyHTML.attribute("href")
    "#" <> note_id = ref
    assert tree |> LazyHTML.query_by_id(note_id) |> LazyHTML.text() =~ "second"
  end

  test "namespaces and names that concatenate alike stay apart", %{scope: scope} do
    a = render("正文[^b-1]\n\n[^b-1]: first\n", scope, anchor_ns: "preview-a")
    b = render("正文[^1]\n\n[^1]: second\n", scope, anchor_ns: "preview-a-b")
    c = render("正文[^1] 又[^1]\n\n[^1]: third\n", scope, anchor_ns: "preview-a")
    d = render("正文[^2]\n\n[^2]: fourth\n", scope, anchor_ns: "preview-a-1")

    for html <- [a, b, c, d], do: assert_footnotes_consistent(html)
    assert_footnotes_consistent(a <> b)
    assert_footnotes_consistent(c <> d)
  end

  property "any notes in any two namespaces render consistent, unique ids", %{scope: scope} do
    name = string(Enum.concat([?a..?c, ?0..?2, [?-]]), min_length: 1, max_length: 4)
    ns = string(Enum.concat([?a..?b, ?0..?2, [?-]]), min_length: 0, max_length: 3)

    check all names_a <- uniq_list_of(name, min_length: 1, max_length: 4),
              names_b <- uniq_list_of(name, min_length: 1, max_length: 4),
              ns_a <- ns,
              ns_b <- ns,
              "a" <> ns_a != "b" <> ns_b,
              max_runs: 50 do
      a = render(doc(names_a), scope, anchor_ns: "a" <> ns_a)
      b = render(doc(names_b), scope, anchor_ns: "b" <> ns_b)
      assert_footnotes_consistent(a <> b)
    end
  end

  # Every note referenced twice, the last one also as a note's own name
  # with `-2` appended.
  defp doc(names) do
    refs = Enum.map_join(names, " ", &"x[^#{&1}] y[^#{&1}]")
    notes = Enum.map_join(names, "\n", &"[^#{&1}]: note #{&1}")
    refs <> "\n\n" <> notes <> "\n"
  end

  test "blocks rendered with different namespaces share a page", %{scope: scope} do
    desc = render(@doc_two, scope, anchor_ns: "desc")
    feedback = render(@doc_two, scope, anchor_ns: "fb-3")
    page = desc <> feedback

    assert length(ids(page)) == length(Enum.uniq(ids(page)))
    for id <- fragments(desc), do: assert(id in ids(desc))
    for id <- fragments(feedback), do: assert(id in ids(feedback))
    assert MapSet.disjoint?(MapSet.new(ids(desc)), MapSet.new(ids(feedback)))
  end

  test "the same input and namespace render the same", %{scope: scope} do
    assert render(@doc_two, scope, anchor_ns: "fb-3") ==
             render(@doc_two, scope, anchor_ns: "fb-3")
  end

  test "a missing or malformed namespace is an argument error", %{scope: scope} do
    for opts <- [
          [scope: scope],
          [scope: scope, anchor_ns: nil],
          [scope: scope, anchor_ns: ""],
          [scope: scope, anchor_ns: "Desc"],
          [scope: scope, anchor_ns: "-desc"],
          [scope: scope, anchor_ns: "fb_3"],
          [scope: scope, anchor_ns: String.duplicate("a", 41)],
          [scope: scope, anchor_ns: :desc]
        ] do
      assert_raise ArgumentError, fn -> HelmsmanWeb.Markdown.to_html(@doc_two, opts) end
    end

    assert {:safe, _} =
             HelmsmanWeb.Markdown.to_html(@doc_two,
               scope: scope,
               anchor_ns: String.duplicate("a", 40)
             )

    assert_raise ArgumentError, fn -> HelmsmanWeb.Markdown.to_html("x", anchor_ns: "desc") end
  end
end
