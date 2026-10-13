defmodule HelmsmanWeb.Markdown do
  @moduledoc """
  Server-side rendering of the Markdown written by people and agents
  (designs/09 §4): task descriptions, feedback and editor previews all go
  through `to_html/2`, so they render the same way.

  The content is untrusted. Raw HTML is shown escaped instead of taking
  effect, and the rendered HTML is then cleaned against an allowlist
  (ammonia): no scripts, styles, frames, event handlers or `style`
  attributes, links only to `http`, `https` and `mailto` (plus same-site
  paths and fragments), every link with `rel="noopener noreferrer nofollow"`.

  ## Output contract

    * code blocks are highlighted with Lumis `html_linked` CSS classes
      (`pre.lumis`, `span.l-*`); the theme CSS is the page's;
    * a ` ```mermaid ` block becomes `pre.hm-mermaid[data-mermaid]`, its
      `code` text the escaped diagram source;
    * a mention on the `:mentions` list becomes
      `span.hm-mention[data-actor=<name>]`;
    * `#BOS-12` and `BOS-12#3` of existing tasks become `a.hm-ref` links to
      the task page (`#feedback-3` for a feedback entry);
    * footnote ids and links carry the `:anchor_ns` of the render, so
      blocks rendered with different namespaces can share a page;
    * images are links to the image address, never embedded.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.Workspaces.Workspace
  alias HelmsmanWeb.Markdown.Transform

  @options [
    extension: [
      table: true,
      tasklist: true,
      strikethrough: true,
      autolink: true,
      footnotes: true
    ],
    render: [unsafe: false, escape: true],
    syntax_highlight: [engine: :lumis, opts: [formatter: :html_linked]]
  ]

  # Added to MDEx.Document.default_sanitize_options/0.
  @sanitize [
    add_tags: ~w(input section),
    rm_tags: ~w(img),
    tag_attributes: %{
      "a" => ~w(href hreflang class id),
      "bdo" => ~w(dir),
      "blockquote" => ~w(cite),
      "code" => ~w(class translate tabindex),
      "col" => ~w(align char charoff span),
      "colgroup" => ~w(align char charoff span),
      "del" => ~w(cite datetime),
      "hr" => ~w(align size width),
      "input" => ~w(checked),
      "ins" => ~w(cite datetime),
      "li" => ~w(id),
      "ol" => ~w(start id),
      "pre" => ~w(class data-mermaid),
      "q" => ~w(cite),
      "section" => ~w(id),
      "span" => ~w(class data-line data-actor data-skipped title),
      "sup" => ~w(id),
      "table" => ~w(align char charoff summary),
      "tbody" => ~w(align char charoff),
      "td" => ~w(align char charoff colspan headers rowspan),
      "tfoot" => ~w(align char charoff),
      "th" => ~w(align char charoff colspan headers rowspan scope),
      "thead" => ~w(align char charoff),
      "tr" => ~w(align char charoff)
    },
    tag_attribute_values: %{"input" => %{"type" => ["checkbox"]}},
    set_tag_attribute_values: %{"input" => %{"disabled" => ""}},
    url_schemes: ~w(http https mailto),
    link_rel: "noopener noreferrer nofollow"
  ]

  @anchor_ns ~r/\A[a-z0-9][a-z0-9-]{0,39}\z/

  @doc """
  Renders `markdown` to safe HTML.

  ## Options

    * `:scope` (required) - the scope of the reader: references are linked
      only to tasks of its workspace, under its slug
    * `:anchor_ns` (required) - the anchor namespace of this rendered
      block, `^[a-z0-9][a-z0-9-]{0,39}$`, unique on the page: `desc` for a
      task description, `fb-<seq>` for a feedback entry,
      `preview-<component id>` for an editor preview
    * `:mentions` - the identity names mentioned by the content (default
      `[]`); others are left as text
    * `:muted_mentions` - `%{name => reason}` of mentions that triggered
      nothing (default `%{}`): their span also gets `data-skipped` and the
      reason as its `title` (add-collaboration-ui D9)

  The same input, namespace, existing tasks and mentions always give the
  same output. Raises `ArgumentError` for a missing or malformed `:scope`
  or `:anchor_ns`.
  """
  @spec to_html(String.t(), keyword()) :: Phoenix.HTML.safe()
  def to_html(markdown, opts) when is_binary(markdown) and is_list(opts) do
    context = %{
      scope: scope!(opts),
      anchor_ns: anchor_ns!(opts),
      mentions: Keyword.get(opts, :mentions, []),
      muted_mentions: Keyword.get(opts, :muted_mentions, %{})
    }

    html =
      markdown
      |> MDEx.parse_document!(@options)
      |> Transform.run(context)
      |> MDEx.to_html!(Keyword.put(@options, :sanitize, @sanitize))

    {:safe, html}
  end

  defp scope!(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, %Scope{workspace: %Workspace{}} = scope} -> scope
      _ -> raise ArgumentError, "Markdown.to_html/2 needs the :scope of a workspace"
    end
  end

  defp anchor_ns!(opts) do
    with {:ok, ns} when is_binary(ns) <- Keyword.fetch(opts, :anchor_ns),
         true <- Regex.match?(@anchor_ns, ns) do
      ns
    else
      _ ->
        raise ArgumentError,
              "Markdown.to_html/2 needs an :anchor_ns matching ^[a-z0-9][a-z0-9-]{0,39}$, " <>
                "got: #{inspect(Keyword.get(opts, :anchor_ns))}"
    end
  end
end
