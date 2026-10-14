defmodule HelmsmanDaemon.Adapters.Codex.Vendor do
  @moduledoc false
  alias HelmsmanDaemon.Adapters.Codex.{Config, Home}
  alias HelmsmanDaemon.Env
  alias HelmsmanProtocol.Vendor

  def infer(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &Env.child/0)
    location = Keyword.get_lazy(opts, :location, fn -> Home.resolve(env) end)

    with {:ok, location} <- location,
         {:ok, config} <- Config.read_validated(location),
         true <- valid_config?(config) do
      provider(config["model_provider"] || "openai", config)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp valid_config?(config) do
    (not Map.has_key?(config, "model_provider") or is_binary(config["model_provider"])) and
      (not Map.has_key?(config, "model_providers") or is_map(config["model_providers"]))
  end

  defp provider("openai", config) do
    case config["openai_base_url"] do
      nil -> "openai"
      url when is_binary(url) -> Vendor.from_base_url(url, "codex")
      _ -> nil
    end
  end

  defp provider("ollama", _config), do: "ollama"
  defp provider("lmstudio", _config), do: nil

  defp provider(id, config) do
    with providers when is_map(providers) <- config["model_providers"],
         provider when is_map(provider) <- providers[id],
         url when is_binary(url) <- provider["base_url"],
         true <- String.trim(url) != "" do
      Vendor.from_base_url(url, "codex")
    else
      _ -> nil
    end
  end
end
