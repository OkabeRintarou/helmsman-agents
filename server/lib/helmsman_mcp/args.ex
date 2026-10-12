defmodule HelmsmanMCP.Args do
  @moduledoc """
  Helpers that turn tool arguments (string keys) into domain input.
  """

  alias Helmsman.Tasks.StateMachine

  @doc """
  The arguments among `keys` that were given, with atom keys. An argument
  that was not given is left out, so the domain keeps its value; one given
  as `null` is passed on as `nil`.
  """
  @spec take(map(), [atom()]) :: map()
  def take(args, keys) when is_map(args) and is_list(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.fetch(args, Atom.to_string(key)) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  @doc """
  Parses a status argument, a name or a list of names, with
  `Helmsman.Tasks.StateMachine.normalize_all/1` (any case, spaces or
  dashes): `{:ok, nil}` when it was not given, the first unknown name as
  `{:error, {:invalid_status, input, valid}}`.
  """
  @spec statuses(term()) ::
          {:ok, [atom()] | nil} | {:error, {:invalid_status, term(), [atom()]}}
  def statuses(nil), do: {:ok, nil}
  def statuses(input), do: StateMachine.normalize_all(input)
end
