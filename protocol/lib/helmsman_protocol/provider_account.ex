defmodule HelmsmanProtocol.ProviderAccount do
  @moduledoc "Provider credentials and model aliases carried in a RunSpec."
  use HelmsmanProtocol.Schema

  @claude_aliases ~w(default opus sonnet haiku fable subagent)
  @codex_aliases ~w(default)
  @aliases Enum.uniq(@claude_aliases ++ @codex_aliases)

  field(:base_url, :string, min_bytes: 1, max_bytes: 2_048)
  field(:api_key, :string, min_bytes: 1, max_bytes: 8_192)
  field(:models, :string_map)
  use HelmsmanProtocol.Redacted, [:api_key]

  @doc "Model alias keys supported by a provider account's CLI."
  @spec model_aliases(:claude | :codex) :: [String.t()]
  def model_aliases(:claude), do: @claude_aliases
  def model_aliases(:codex), do: @codex_aliases

  @doc false
  def validate(%{models: models} = account) do
    cond do
      map_size(models) > 8 ->
        HelmsmanProtocol.Schema.invalid(["models"], {:count, 0, 8})

      Enum.any?(models, fn {key, _} -> key not in @aliases end) ->
        HelmsmanProtocol.Schema.invalid(["models"], {:enum, @aliases})

      Enum.any?(models, fn {_, value} -> byte_size(value) == 0 end) ->
        HelmsmanProtocol.Schema.invalid(["models"], :type)

      Enum.any?(models, fn {_, value} -> byte_size(value) > 128 end) ->
        HelmsmanProtocol.Schema.invalid(["models"], {:too_long, 128})

      true ->
        {:ok, account}
    end
  end
end
