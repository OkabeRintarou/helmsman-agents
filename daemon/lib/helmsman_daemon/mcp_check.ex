defmodule HelmsmanDaemon.McpCheck do
  @moduledoc "Read-only command lookup; never runs MCP programs or resolves network addresses."
  import Bitwise
  alias HelmsmanDaemon.McpEnv
  alias HelmsmanProtocol.{McpCheckResult, Report}

  def execute(request, provider, base \\ System.get_env()) do
    env = McpEnv.cli_env(base, request.agent_env)
    results = Enum.map(request.servers, &check(&1, provider, env))
    %Report.McpCheckResult{check_id: request.check_id, results: results}
  end

  defp check(server, provider, env) do
    refs = Enum.uniq(server.env_refs ++ McpEnv.references(server.command))
    missing = Enum.filter(refs, &(McpEnv.reserved?(&1) or not Map.has_key?(env, &1)))

    dropped =
      case {to_string(provider), server.type, server.command} do
        {"codex", :sse, _} -> :unsupported_type
        {"codex", :stdio, command} when command in [nil, ""] -> :missing_target
        _ -> nil
      end

    found = command_found(server, env)

    %McpCheckResult{
      name: server.name,
      command_found: found,
      missing_env: missing,
      dropped: dropped
    }
  end

  defp command_found(%{type: type}, _) when type != :stdio, do: :"n/a"

  defp command_found(server, env) do
    case McpEnv.expand(server.command, env) do
      {:ok, command} -> if executable?(command, env["PATH"] || ""), do: :yes, else: :no
      _ -> :no
    end
  end

  defp executable?(command, path) when is_binary(command) and command != "" do
    paths =
      if String.contains?(command, "/"),
        do: [command],
        else: Enum.map(String.split(path, ":"), &Path.join(&1, command))

    Enum.any?(paths, fn candidate ->
      case File.stat(candidate) do
        {:ok, %{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
        _ -> false
      end
    end)
  end

  defp executable?(_, _), do: false
end
