defmodule Helmsman.Tasks.Ident do
  @moduledoc """
  Task IDs (`KEY-N`): parsed case-insensitively, `N` a positive integer
  without leading zeros.
  """

  @format ~r/\A([A-Za-z][A-Za-z0-9]{1,9})-([1-9][0-9]*)\z/

  @doc """
  Parses a task ID into its canonical form, the upcased key and the number.

      iex> Helmsman.Tasks.Ident.parse("bos-12")
      {:ok, "BOS-12", "BOS", 12}

      iex> Helmsman.Tasks.Ident.parse("BOS-03")
      {:error, :not_found}
  """
  @spec parse(term()) ::
          {:ok, String.t(), String.t(), pos_integer()} | {:error, :not_found}
  def parse(ident) when is_binary(ident) do
    case Regex.run(@format, ident) do
      [_, key, seq] ->
        key = String.upcase(key)
        {:ok, "#{key}-#{seq}", key, String.to_integer(seq)}

      nil ->
        {:error, :not_found}
    end
  end

  def parse(_ident), do: {:error, :not_found}

  @doc "Builds the ID of task number `seq` in the project with `key`."
  @spec build(String.t(), pos_integer()) :: String.t()
  def build(key, seq) when is_binary(key) and is_integer(seq) and seq > 0, do: "#{key}-#{seq}"
end
