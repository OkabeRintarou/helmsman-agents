defmodule Helmsman.Search.Document do
  @moduledoc """
  The search column values (`add-fulltext-search` decision 4,
  designs/10 §1.2), written as `%Postgrex.Lexeme{}` lists in the binary
  protocol.

  Fields are tokenized one after the other: the first starts at position
  1, each next one 10 positions after the last position the previous one
  used (an empty field uses none), so no phrase spans two fields. A
  term's positions are merged, sorted and capped at 256 (PostgreSQL's
  limit); positions above 16383 are left out rather than squeezed onto
  16383, and a term left without positions is written without them (it
  still matches, ranked low).
  """

  alias Helmsman.Search.Tokenizer

  @type weight :: :A | :B | :C
  @field_gap 10
  @max_position 16_383
  @max_positions 256

  @doc """
  The search column of a task: ID, labels (one after the other) and title
  weighted A, description B.
  """
  @spec task(%{
          required(:ident) => String.t(),
          required(:labels) => [String.t()] | nil,
          required(:title) => String.t(),
          required(:description) => String.t() | nil,
          optional(atom()) => term()
        }) :: [Postgrex.Lexeme.t()]
  def task(%{ident: ident, labels: labels, title: title, description: description}) do
    build([
      {[ident], :A},
      {labels || [], :A},
      {[title], :A},
      {[description || ""], :B}
    ])
  end

  @doc "The search column of an active feedback record: its content, weighted C."
  @spec feedback(String.t()) :: [Postgrex.Lexeme.t()]
  def feedback(content) when is_binary(content), do: build([{[content], :C}])

  @doc """
  Builds the lexemes of `fields`, `{texts, weight}` each, in order. The
  texts of one field follow each other without a gap.
  """
  @spec build([{[String.t() | nil], weight()}]) :: [Postgrex.Lexeme.t()]
  def build(fields) do
    fields
    |> Enum.reduce({[], nil}, fn {texts, weight}, {acc, last} ->
      place(field_tokens(texts), weight, acc, last)
    end)
    |> elem(0)
    |> List.flatten()
    |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})
    |> Enum.map(fn {term, positions} ->
      %Postgrex.Lexeme{word: term, positions: positions(positions)}
    end)
    |> Enum.sort_by(& &1.word)
  end

  # An empty field takes no positions; the first one starts at 1, the next
  # ones `@field_gap` after the last position used.
  defp place([], _weight, acc, last), do: {acc, last}

  defp place(tokens, weight, acc, last) do
    base = if last, do: last + @field_gap, else: 1
    placed = Enum.map(tokens, fn {term, pos} -> {term, pos + base, weight} end)
    {[placed | acc], placed |> Enum.map(&elem(&1, 1)) |> Enum.max()}
  end

  # `{term, position from 0}` of the texts of one field.
  defp field_tokens(texts) do
    texts
    |> Enum.reduce({[], 0}, fn text, {acc, next} ->
      case Tokenizer.tokens(text || "") do
        [] ->
          {acc, next}

        tokens ->
          placed = Enum.map(tokens, &{&1.term, &1.pos + next})
          {[placed | acc], (placed |> Enum.map(&elem(&1, 1)) |> Enum.max()) + 1}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.flatten()
  end

  defp positions(positions) do
    positions
    |> Enum.filter(fn {pos, _weight} -> pos <= @max_position end)
    |> Enum.sort()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.take(@max_positions)
  end
end
