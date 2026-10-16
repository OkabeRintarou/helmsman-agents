defmodule HelmsmanDaemon.McpEnv do
  @moduledoc "Resolve local MCP references using the same environment as the CLI subprocess."
  alias HelmsmanDaemon.Env
  @reference ~r/\$\{env:([A-Za-z_][A-Za-z0-9_]{0,127})\}/

  def cli_env(base, agent_env), do: Env.agent(Map.new(base), agent_env || %{})

  def resolve(servers, env) do
    Enum.reduce(servers || %{}, {%{}, []}, fn {name, entry}, {kept, warnings} ->
      case expand(entry, env) do
        {:ok, expanded} ->
          {Map.put(kept, name, expanded), warnings}

        {:error, missing} ->
          message = "MCP 服务器 #{name} 未启用：执行机器上没有设置 #{Enum.join(missing, ", ")}"
          {kept, warnings ++ [{:status, %{level: :warning, message: message}}]}
      end
    end)
  end

  def expand(value, env) do
    missing = references(value) |> Enum.filter(&(reserved?(&1) or not Map.has_key?(env, &1)))
    if missing == [], do: {:ok, replace(value, env)}, else: {:error, missing}
  end

  def references(value) when is_binary(value),
    do: Regex.scan(@reference, value, capture: :all_but_first) |> List.flatten() |> Enum.uniq()

  def references(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&references/1) |> Enum.uniq()

  def references(value) when is_list(value),
    do: value |> Enum.flat_map(&references/1) |> Enum.uniq()

  def references(_), do: []
  def reserved?(name), do: String.starts_with?(String.upcase(name), "HELMSMAN_")

  defp replace(value, env) when is_binary(value),
    do: Regex.replace(@reference, value, fn _, name -> Map.fetch!(env, name) end)

  defp replace(value, env) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, replace(v, env)} end)

  defp replace(value, env) when is_list(value), do: Enum.map(value, &replace(&1, env))
  defp replace(value, _), do: value
end
