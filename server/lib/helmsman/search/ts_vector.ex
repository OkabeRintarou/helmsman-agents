defmodule Helmsman.Search.TsVector do
  @moduledoc """
  Ecto type of the `search` columns (`tsvector`): a list of
  `%Postgrex.Lexeme{}` (`Helmsman.Search.Document`) or `nil`, sent in the
  binary protocol, so nothing is ever escaped.
  """

  use Ecto.Type

  @type t :: [Postgrex.Lexeme.t()] | nil

  @impl Ecto.Type
  def type, do: :tsvector

  @impl Ecto.Type
  def cast(value), do: check(value)

  @impl Ecto.Type
  def dump(value), do: check(value)

  @impl Ecto.Type
  def load(value), do: check(value)

  defp check(nil), do: {:ok, nil}

  defp check(lexemes) when is_list(lexemes) do
    if Enum.all?(lexemes, &match?(%Postgrex.Lexeme{word: word} when is_binary(word), &1)),
      do: {:ok, lexemes},
      else: :error
  end

  defp check(_other), do: :error
end
