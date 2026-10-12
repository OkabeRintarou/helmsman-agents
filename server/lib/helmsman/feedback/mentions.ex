defmodule Helmsman.Feedback.Mentions do
  @moduledoc """
  `@name` mentions in feedback content (designs/06).

  `extract/1` parses the Markdown with MDEx (GitHub-flavoured extensions)
  and scans only the text a reader sees as prose: code (inline and blocks),
  link and image text and raw HTML are skipped, so `npm i @types/node` in
  backticks or a GFM e-mail autolink (`bob@alice.com`) mention no one.

  After an `@` that does not follow an identity character, the whole run
  of identity characters is taken, however long. `resolve/2` then tries
  that run and the names obtained by dropping trailing `.`, `-` and `/`
  one at a time (`@alice.` → `alice`, `@keel/dev/` → `keel/dev`), never a
  prefix cut out of a longer name: `@` and 65 characters never mention an
  identity named by the first 64.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Actors.Actor
  alias Helmsman.Repo

  # GitHub-flavoured Markdown, as the content is rendered.
  @parse_options [
    extension: [autolink: true, strikethrough: true, table: true, tasklist: true]
  ]

  @mention ~r/(?<![A-Za-z0-9._\/@-])@([A-Za-z0-9][A-Za-z0-9._\/-]*)/
  @name_format ~r/\A[a-z0-9][a-z0-9._\/-]{0,63}\z/

  # Subtrees whose text is not prose.
  @skipped [
    MDEx.Code,
    MDEx.CodeBlock,
    MDEx.Link,
    MDEx.Image,
    MDEx.HtmlInline,
    MDEx.HtmlBlock,
    MDEx.WikiLink,
    MDEx.Math
  ]

  @doc """
  The MDEx options the content is parsed with; rendering uses the same, so
  what is shown as code is never taken for a mention.
  """
  @spec parse_options() :: keyword()
  def parse_options, do: @parse_options

  @doc """
  The mention candidates in `content`: the full run of identity characters
  after each mentioning `@`, in order of appearance, duplicates removed.

      iex> Helmsman.Feedback.Mentions.extract("cc @alice. and `@bob`")
      ["alice."]
  """
  @spec extract(String.t()) :: [String.t()]
  def extract(content) when is_binary(content) do
    content
    |> MDEx.parse_document!(@parse_options)
    |> prose()
    |> Enum.flat_map(&Regex.scan(@mention, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
  end

  # The prose of a node's children: runs of adjacent text nodes are joined,
  # so a name is never split by how the parser cut the text.
  defp prose(%{nodes: children}) do
    {texts, run} =
      Enum.reduce(children, {[], []}, fn
        %MDEx.Text{literal: literal}, {texts, run} -> {texts, [literal | run]}
        %MDEx.SoftBreak{}, {texts, run} -> {texts, ["\n" | run]}
        %MDEx.LineBreak{}, {texts, run} -> {texts, ["\n" | run]}
        %module{}, {texts, run} when module in @skipped -> {flush(texts, run), []}
        child, {texts, run} -> {Enum.reverse(prose(child), flush(texts, run)), []}
      end)

    Enum.reverse(flush(texts, run))
  end

  defp prose(_leaf), do: []

  defp flush(texts, []), do: texts
  defp flush(texts, run), do: [run |> Enum.reverse() |> IO.iodata_to_binary() | texts]

  @doc """
  Resolves `candidates` (from `extract/1`) to the ids of the identities of
  the workspace they name, case-insensitively, in order of appearance and
  without duplicates. Each candidate names the identity matching its
  longest variant (see the module documentation); candidates naming no one
  are ignored. One query, none for no candidates.
  """
  @spec resolve(pos_integer(), [String.t()]) :: [pos_integer()]
  def resolve(workspace_id, candidates) when is_integer(workspace_id) and is_list(candidates) do
    variants = Enum.map(candidates, &variants/1)

    case variants |> List.flatten() |> Enum.uniq() do
      [] ->
        []

      names ->
        ids =
          from(a in Actor,
            where: a.workspace_id == ^workspace_id and a.name in ^names,
            select: {a.name, a.id}
          )
          |> Repo.all()
          |> Map.new(fn {name, id} -> {String.downcase(name), id} end)

        variants
        |> Enum.map(fn longest_first -> Enum.find_value(longest_first, &ids[&1]) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  end

  # The candidate and the names left by dropping its trailing '.', '-' and
  # '/' one at a time, downcased, longest first; only valid identity names.
  defp variants(candidate) do
    candidate
    |> String.downcase()
    |> Stream.unfold(fn
      "" -> nil
      name -> {name, strip_last(name)}
    end)
    |> Enum.filter(&Regex.match?(@name_format, &1))
  end

  defp strip_last(name) do
    if String.ends_with?(name, [".", "-", "/"]),
      do: binary_part(name, 0, byte_size(name) - 1),
      else: ""
  end
end
