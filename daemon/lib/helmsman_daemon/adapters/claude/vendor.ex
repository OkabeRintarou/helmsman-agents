defmodule HelmsmanDaemon.Adapters.Claude.Vendor do
  @moduledoc false
  alias HelmsmanDaemon.Env
  alias HelmsmanProtocol.Vendor

  # Inject paths and environment in tests; inference never executes a CLI.
  def infer(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &Env.child/0)
    managed = Keyword.get_lazy(opts, :managed_path, &managed_path/0)
    home = Keyword.get_lazy(opts, :home, fn -> env["HOME"] || System.user_home!() end)
    config_dir = nonempty(env["CLAUDE_CONFIG_DIR"]) || Path.join(home, ".claude")

    with {:ok, user} <- settings(Path.join(config_dir, "settings.json")),
         {:ok, managed} <- settings(managed) do
      env |> Map.merge(user) |> Map.merge(managed) |> infer_env()
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp managed_path do
    case :os.type() do
      {:unix, :darwin} -> "/Library/Application Support/ClaudeCode/managed-settings.json"
      _ -> "/etc/claude-code/managed-settings.json"
    end
  end

  defp settings(path) do
    case File.read(path) do
      {:error, :enoent} -> {:ok, %{}}
      {:ok, json} -> decode(json)
      _ -> :error
    end
  end

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, settings} when is_map(settings) -> settings_env(Map.get(settings, "env", %{}))
      _ -> :error
    end
  end

  defp settings_env(env) when is_map(env) do
    if Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end),
      do: {:ok, env},
      else: :error
  end

  defp settings_env(_), do: :error

  defp infer_env(env) do
    cond do
      truthy?(env["CLAUDE_CODE_USE_BEDROCK"]) ->
        "bedrock"

      truthy?(env["CLAUDE_CODE_USE_VERTEX"]) ->
        "vertexai"

      truthy?(env["CLAUDE_CODE_USE_FOUNDRY"]) ->
        "azure"

      Enum.any?(env, fn {key, value} ->
        String.starts_with?(key, "CLAUDE_CODE_USE_") and truthy?(value)
      end) ->
        nil

      true ->
        Vendor.from_base_url(env["ANTHROPIC_BASE_URL"], "claude")
    end
  end

  defp truthy?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ~w(1 true yes on)

  defp truthy?(_), do: false
  defp nonempty(value) when is_binary(value) and value != "", do: value
  defp nonempty(_), do: nil
end
