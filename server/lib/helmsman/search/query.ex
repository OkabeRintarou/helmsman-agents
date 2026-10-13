defmodule Helmsman.Search.Query do
  @moduledoc """
  Query strings (`add-fulltext-search` decision 6): validated, tokenized
  with `Helmsman.Search.Tokenizer.query/1` and written as `tsquery` text,
  passed to PostgreSQL as a text parameter cast in SQL
  (`$1::text::tsquery`).
  """

  alias Helmsman.Search.Tokenizer

  @max_length 200

  @type error :: {:invalid_query, :not_a_string | :too_long}

  @doc "The longest query string, in characters."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Reads a query string: `:blank` when it is empty once trimmed, else its
  groups (possibly none, when it has only stop words or separators).
  """
  @spec parse(term()) :: {:ok, :blank | [Tokenizer.group()]} | {:error, error()}
  def parse(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" -> {:ok, :blank}
      String.length(query) > @max_length -> {:error, {:invalid_query, :too_long}}
      true -> {:ok, Tokenizer.query(query)}
    end
  end

  def parse(_query), do: {:error, {:invalid_query, :not_a_string}}

  @doc """
  The `tsquery` text of `groups`, ANDed: a term is `'t'`, a prefix `'t':*`
  and a phrase `('a' <-> 'b')`. Quotes are doubled and backslashes
  escaped. `nil` without groups.
  """
  @spec to_tsquery([Tokenizer.group()]) :: String.t() | nil
  def to_tsquery([]), do: nil
  def to_tsquery(groups) when is_list(groups), do: Enum.map_join(groups, " & ", &group/1)

  defp group({:term, term}), do: quote_term(term)
  defp group({:prefix, term}), do: quote_term(term) <> ":*"
  defp group({:phrase, terms}), do: "(" <> Enum.map_join(terms, " <-> ", &quote_term/1) <> ")"

  defp quote_term(term),
    do: "'" <> (term |> String.replace("\\", "\\\\") |> String.replace("'", "''")) <> "'"
end
