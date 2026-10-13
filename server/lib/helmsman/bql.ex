defmodule Helmsman.BQL do
  @moduledoc "BQL parsing, canonical printing and field metadata."
  alias Helmsman.BQL.{Fields, Normalizer, Parser, Printer, Validator}
  @type ast :: %{where: term(), order: [{atom(), :asc | :desc}]}
  @type error :: {:invalid_bql, %{message: String.t(), position: pos_integer()}}
  @spec parse(term(), keyword()) :: {:ok, ast()} | {:error, error()}
  def parse(input, opts \\ []) do
    with {:ok, raw} <- Parser.parse(input), do: Normalizer.normalize(raw, opts)
  end

  @doc "Validates a canonical AST without reinterpreting generated source text."
  @spec validate_ast(term()) :: {:ok, ast()} | {:error, error()}
  def validate_ast(ast), do: Validator.validate(ast)

  @spec fields() :: [map()]
  def fields,
    do: Enum.map(Fields.all(), &Map.update!(&1, :values, fn v -> Normalizer.values(v) end))

  @spec to_string(ast()) :: String.t()
  def to_string(ast), do: Printer.print(ast)
end
