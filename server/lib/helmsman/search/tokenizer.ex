defmodule Helmsman.Search.Tokenizer do
  @moduledoc """
  The tokenizer of full-text search (`add-fulltext-search` decision 3),
  used to build the index (`Helmsman.Search.Document`), the query
  (`Helmsman.Search.Query`) and the snippets (`Helmsman.Search.Snippet`).

  Replaceable: `config :helmsman, Helmsman.Search, tokenizer: Module`;
  after a change run `mix helmsman.reindex`.
  """

  @typedoc """
  A term with its position (from 0, never decreasing along the list; the
  fragments of a word share its position) and the byte offset and length
  of its source in the original text.
  """
  @type token :: %{
          term: String.t(),
          pos: non_neg_integer(),
          start: non_neg_integer(),
          len: pos_integer()
        }

  @typedoc "One condition of a query; the groups of a query are ANDed."
  @type group :: {:term, String.t()} | {:prefix, String.t()} | {:phrase, [String.t(), ...]}

  @callback tokens(String.t()) :: [token()]
  @callback query(String.t()) :: [group()]

  @doc "The configured tokenizer (default `Helmsman.Search.Tokenizer.Bigram`)."
  @spec impl() :: module()
  def impl do
    :helmsman
    |> Application.get_env(Helmsman.Search, [])
    |> Keyword.get(:tokenizer, Helmsman.Search.Tokenizer.Bigram)
  end

  @doc "`tokens/1` of the configured tokenizer."
  @spec tokens(String.t()) :: [token()]
  def tokens(text) when is_binary(text), do: impl().tokens(text)

  @doc "`query/1` of the configured tokenizer."
  @spec query(String.t()) :: [group()]
  def query(text) when is_binary(text), do: impl().query(text)
end
