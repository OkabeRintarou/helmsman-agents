defmodule HelmsmanDaemon.Adapters.Copilot.Environment do
  @moduledoc false

  def drop?(name) do
    String.starts_with?(name, "COPILOT_") and
      name not in ["COPILOT_GITHUB_TOKEN", "COPILOT_GH_HOST"] and
      not String.starts_with?(name, "COPILOT_PROVIDER_")
  end

  def clean(env, home) do
    env
    |> Map.new()
    |> Map.reject(fn {name, _} -> drop?(name) end)
    |> Map.put("COPILOT_HOME", home)
    |> Map.put("COPILOT_AUTO_UPDATE", "false")
  end
end
