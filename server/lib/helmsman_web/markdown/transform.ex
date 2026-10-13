defmodule HelmsmanWeb.Markdown.Transform do
  @moduledoc false
  # The changes `HelmsmanWeb.Markdown` makes to the parsed document before
  # it is rendered (add-markdown-rendering, decision 3). Nodes emitted as
  # `MDEx.Raw` are built from escaped values only and are still sanitized.

  alias Helmsman.Feedback.Mentions
  alias Helmsman.Tasks
  alias Helmsman.Tasks.Ident

  # `#BOS-12` (task) or `BOS-12#3` (feedback entry 3 of the task).
  @ref ~r/(?<![A-Za-z0-9#\/-])(?:#([A-Za-z][A-Za-z0-9]{1,9}-[1-9][0-9]*)(?![A-Za-z0-9#-])|([A-Za-z][A-Za-z0-9]{1,9}-[1-9][0-9]*)#([1-9][0-9]*)(?![A-Za-z0-9]))/

  # Subtrees whose text is not prose: references and mentions in them stay
  # as written. Images and code blocks are replaced before this applies.
  @skipped [
    MDEx.Code,
    MDEx.Link,
    MDEx.HtmlInline,
    MDEx.HtmlBlock,
    MDEx.WikiLink,
    MDEx.Math,
    MDEx.Raw
  ]

  @spec run(MDEx.Document.t(), map()) :: MDEx.Document.t()
  def run(%MDEx.Document{} = document, %{scope: scope, anchor_ns: ns, mentions: mentions} = opts) do
    document = namespace_footnotes(document, ns)

    candidates =
      for text <- prose(document),
          {_at, _length, ident, _seq} <- refs(text),
          uniq: true,
          do: ident

    context = %{
      slug: scope.workspace.slug,
      existing: Tasks.existing_idents(scope, candidates),
      mentions: Map.new(mentions, &{String.downcase(&1), &1}),
      muted:
        Map.new(Map.get(opts, :muted_mentions, %{}), fn {k, v} -> {String.downcase(k), v} end)
    }

    transform(document, context)
  end

  ## Footnotes

  # comrak derives the footnote ids and both directions of links from the
  # names, so renaming both ends keeps every link pointing at its target.
  # Each footnote is renamed `<ns>_<number>` after the number it is shown
  # with: the namespace has no `_`, and the number and the `-<n>` comrak
  # appends to repeated references are digits, so no two ids of a render or
  # of renders with different namespaces can be equal.
  defp namespace_footnotes(document, ns) do
    numbers =
      for %MDEx.FootnoteReference{name: name, ix: ix} <- descendants(document),
          into: %{},
          do: {name, ix}

    MDEx.Document.update_nodes(
      document,
      &(is_struct(&1, MDEx.FootnoteReference) or is_struct(&1, MDEx.FootnoteDefinition)),
      fn node -> %{node | name: footnote_name(ns, node, numbers)} end
    )
  end

  defp footnote_name(ns, %MDEx.FootnoteReference{ix: ix}, _numbers), do: "#{ns}_#{ix}"

  # comrak drops the definitions no reference resolves to; one left over
  # still gets a name of its own.
  defp footnote_name(ns, %MDEx.FootnoteDefinition{name: name}, numbers) do
    case numbers do
      %{^name => ix} -> "#{ns}_#{ix}"
      _ -> "#{ns}_0#{Base.url_encode64(name, padding: false)}"
    end
  end

  defp descendants(%{nodes: children}), do: Enum.flat_map(children, &[&1 | descendants(&1)])
  defp descendants(_leaf), do: []

  ## Prose

  # The text of the document a reader sees as prose, adjacent text nodes
  # joined.
  defp prose(%{nodes: children}) do
    children
    |> merge_texts()
    |> Enum.flat_map(fn
      %MDEx.Text{literal: literal} -> [literal]
      %module{} when module in [MDEx.Image, MDEx.CodeBlock | @skipped] -> []
      child -> prose(child)
    end)
  end

  defp prose(_leaf), do: []

  defp merge_texts(children) do
    children
    |> Enum.chunk_by(&is_struct(&1, MDEx.Text))
    |> Enum.flat_map(fn
      [%MDEx.Text{} = first | _] = texts ->
        [%{first | literal: Enum.map_join(texts, & &1.literal)}]

      others ->
        others
    end)
  end

  ## Transforming

  defp transform(%{nodes: children} = node, context) do
    %{node | nodes: children |> merge_texts() |> Enum.flat_map(&transform_child(&1, context))}
  end

  defp transform(leaf, _context), do: leaf

  defp transform_child(%MDEx.Text{literal: literal}, context), do: annotate(literal, context)
  defp transform_child(%MDEx.Image{} = image, _context), do: link_with_images(image)
  defp transform_child(%MDEx.Link{} = link, _context), do: link_with_images(link)
  defp transform_child(%MDEx.CodeBlock{} = block, _context), do: [code_block(block)]
  defp transform_child(%module{} = node, _context) when module in @skipped, do: [node]
  defp transform_child(node, context), do: [transform(node, context)]

  # Images are never embedded: an image becomes a link to its address, its
  # alt text the link text (the address when empty). Links cannot nest, so
  # images and links inside a link or an image's alt text are reduced to
  # their text, and each such image follows as a link of its own, its
  # address the link text.
  defp link_with_images(%{url: url, title: title, nodes: children}) do
    {children, images} = flatten(children)
    children = if children == [], do: [%MDEx.Text{literal: url}], else: children
    [%MDEx.Link{url: url, title: title, nodes: children} | image_links(images)]
  end

  defp image_links(images) do
    Enum.flat_map(images, fn url ->
      [%MDEx.Text{literal: " "}, %MDEx.Link{url: url, nodes: [%MDEx.Text{literal: url}]}]
    end)
  end

  # The nodes with every link and image replaced by its content, and the
  # addresses of the images, in order.
  defp flatten(nodes) do
    {nodes, images} =
      Enum.reduce(nodes, {[], []}, fn
        %MDEx.Image{url: url, nodes: children}, {acc, images} ->
          {inner, inner_images} = flatten(children)
          {Enum.reverse(inner, acc), Enum.reverse([url | inner_images], images)}

        %MDEx.Link{nodes: children}, {acc, images} ->
          {inner, inner_images} = flatten(children)
          {Enum.reverse(inner, acc), Enum.reverse(inner_images, images)}

        %{nodes: children} = node, {acc, images} ->
          {inner, inner_images} = flatten(children)
          {[%{node | nodes: inner} | acc], Enum.reverse(inner_images, images)}

        leaf, {acc, images} ->
          {[leaf | acc], images}
      end)

    {Enum.reverse(nodes), Enum.reverse(images)}
  end

  defp code_block(%MDEx.CodeBlock{info: info, literal: literal} = block) do
    if mermaid?(info) do
      %MDEx.Raw{
        literal:
          ~s(<pre class="hm-mermaid" data-mermaid="true"><code>) <>
            escape(literal) <> "</code></pre>\n"
      }
    else
      block
    end
  end

  defp mermaid?(info) do
    case String.split(info) do
      [language | _] -> String.downcase(language) == "mermaid"
      [] -> false
    end
  end

  ## References and mentions

  # The text as text nodes and the raw nodes of the references to existing
  # tasks and of the mentions on the list; of two that overlap, the first
  # wins.
  defp annotate(text, context) do
    marks =
      (ref_marks(text, context) ++ mention_marks(text, context))
      |> Enum.sort_by(fn {at, _length, _html} -> at end)

    {nodes, rest} =
      Enum.reduce(marks, {[], 0}, fn
        {at, length, html}, {nodes, from} when at >= from ->
          {[%MDEx.Raw{literal: html} | text_node(text, from, at, nodes)], at + length}

        _overlapping, acc ->
          acc
      end)

    text |> text_node(rest, byte_size(text), nodes) |> Enum.reverse()
  end

  defp text_node(_text, from, from, nodes), do: nodes

  defp text_node(text, from, to, nodes),
    do: [%MDEx.Text{literal: binary_part(text, from, to - from)} | nodes]

  defp refs(text) do
    for [{at, length} | groups] <- Regex.scan(@ref, text, return: :index) do
      case Enum.map(groups, &group(text, &1)) do
        [ident] -> {at, length, canonical(ident), nil}
        ["", ident, seq] -> {at, length, canonical(ident), seq}
      end
    end
  end

  # A group that took no part in the match is reported at -1.
  defp group(_text, {-1, 0}), do: ""
  defp group(text, {start, length}), do: binary_part(text, start, length)

  defp canonical(ident) do
    {:ok, canonical, _key, _seq} = Ident.parse(ident)
    canonical
  end

  defp ref_marks(text, %{existing: existing, slug: slug}) do
    for {at, length, ident, seq} <- refs(text), MapSet.member?(existing, ident) do
      {label, path} =
        case seq do
          nil -> {ident, "/w/#{slug}/t/#{ident}"}
          seq -> {"#{ident}##{seq}", "/w/#{slug}/t/#{ident}#feedback-#{seq}"}
        end

      {at, length, ~s(<a class="hm-ref" href="#{escape(path)}">#{escape(label)}</a>)}
    end
  end

  defp mention_marks(_text, %{mentions: mentions}) when map_size(mentions) == 0, do: []

  # The names are ASCII, so the matched name is as long as the text it
  # replaces after the `@`.
  defp mention_marks(text, %{mentions: mentions} = context) do
    for {at, candidate} <- Mentions.scan(text),
        matched = Enum.find(Mentions.names(candidate), &Map.has_key?(mentions, &1)),
        matched != nil do
      name = escape(Map.fetch!(mentions, matched))
      {at, 1 + byte_size(matched), mention_span(name, Map.get(context.muted, matched))}
    end
  end

  defp mention_span(name, nil),
    do: ~s(<span class="hm-mention" data-actor="#{name}">@#{name}</span>)

  defp mention_span(name, reason),
    do:
      ~s(<span class="hm-mention" data-actor="#{name}" data-skipped="true" title="#{escape(reason)}">@#{name}</span>)

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
