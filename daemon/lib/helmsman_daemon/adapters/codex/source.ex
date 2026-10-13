defmodule HelmsmanDaemon.Adapters.Codex.Source do
  @moduledoc false
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Config
  alias HelmsmanDaemon.Exec
  # codex-cli 0.162.1; oss is a CLI mode, not a provider ID.
  @builtin ~w(ollama lmstudio)

  def check(%{agent: %{provider_account: account}}, _home, _env) when not is_nil(account),
    do: {:ok, :account}

  def check(spec, home, env) do
    case Config.read(home) do
      {:ok, config} -> check(spec, home, env, config)
      _ -> {:unknown, :config}
    end
  end

  def check(%{agent: %{provider_account: account}}, _home, _env, _config)
      when not is_nil(account),
      do: {:ok, :account}

  def check(spec, home, env, config) do
    args = if spec, do: elem(Config.filter(spec.agent.custom_args), 0), else: []
    overrides = overrides(args)

    case argument_provider(overrides) || Map.get(config, "model_provider", "openai") do
      id when is_binary(id) and id != "" -> source(id, config, overrides, home, Map.new(env))
      _ -> {:unknown, :config}
    end
  end

  defp source("openai", _config, _overrides, home, env), do: login(home, env)

  defp source(id, _config, _overrides, _home, _env) when id in @builtin,
    do: {:ok, :builtin_provider}

  defp source(id, config, overrides, home, env) do
    if defined_in_args?(overrides, id) do
      {:ok, :custom_provider}
    else
      case provider(config, id) do
        provider when is_map(provider) -> configured(id, provider, home, env)
        _ -> {:error, {:undefined_provider, id}}
      end
    end
  end

  defp provider(%{"model_providers" => providers}, id) when is_map(providers),
    do: Map.get(providers, id)

  defp provider(_config, _id), do: nil

  defp configured(id, provider, home, env) do
    key = provider["env_key"]

    cond do
      is_binary(key) and key != "" and env[key] in [nil, ""] ->
        {:error, {:missing_env_key, id, key}}

      provider["requires_openai_auth"] == true ->
        login(home, env)

      true ->
        {:ok, :custom_provider}
    end
  end

  def warnings(spec, config, env) do
    args = if spec, do: elem(Config.filter(spec.agent.custom_args), 0), else: []

    with true <- is_nil(spec.agent.provider_account),
         id when is_binary(id) <- argument_provider(overrides(args)) || config["model_provider"],
         false <- defined_in_args?(overrides(args), id),
         provider when is_map(provider) <- provider(config, id),
         headers when is_map(headers) <- provider["env_http_headers"] do
      names =
        headers
        |> Map.values()
        |> Enum.filter(&(is_binary(&1) and env[&1] in [nil, ""]))
        |> Enum.uniq()
        |> Enum.sort()

      if names == [],
        do: [],
        else:
          Codex.warning(
            "Codex provider header environment variables are not set: " <> Enum.join(names, ", ")
          )
    else
      _ -> []
    end
  end

  def guidance(home),
    do:
      "Bind a provider account to the agent, or configure Codex: CODEX_HOME=#{home} codex login, or a model provider in #{Path.join(home, "config.toml")}."

  def error(:none, home), do: "Codex has no model provider. " <> guidance(home)

  def error({:undefined_provider, id}, home),
    do:
      "Codex model provider #{id} is not defined in #{Path.join(home, "config.toml")} or in the agent's arguments. " <>
        guidance(home)

  def error({:missing_env_key, id, key}, home),
    do:
      "Codex model provider #{id} needs environment variable #{key}, which is not set for the daemon or the agent. " <>
        guidance(home)

  defp overrides([]), do: []

  defp overrides([flag, value | rest]) when flag in ["-c", "--config"],
    do: [split(value) | overrides(rest)]

  defp overrides([arg | rest]) do
    case String.split(arg, "=", parts: 2) do
      [flag, value] when flag in ["-c", "--config"] ->
        [split(value) | overrides(rest)]

      _ ->
        overrides(rest)
    end
  end

  defp split(value) do
    [key | raw] = String.split(value, "=", parts: 2)
    {String.replace(key, ~r/[\s"']/, ""), List.first(raw)}
  end

  defp argument_provider(overrides) do
    Enum.reduce(overrides, nil, fn
      {"model_provider", raw}, _ -> decoded(raw)
      _, previous -> previous
    end)
  end

  defp decoded(raw) when is_binary(raw) do
    case Toml.decode("value=" <> raw) do
      {:ok, %{"value" => value}} -> value
      _ -> String.trim(raw)
    end
  end

  defp decoded(_), do: nil

  defp defined_in_args?(overrides, id) do
    key = "model_providers." <> id

    Enum.any?(overrides, fn
      {"model_providers", raw} ->
        case Toml.decode("model_providers=" <> (raw || "")) do
          {:ok, %{"model_providers" => providers}} when is_map(providers) ->
            Map.has_key?(providers, id)

          _ ->
            false
        end

      {candidate, _} ->
        candidate == key or String.starts_with?(candidate, key <> ".")
    end)
  end

  defp login(home, env) do
    env = Map.put(env, "CODEX_HOME", home)

    case System.find_executable(Codex.executable()) do
      nil ->
        {:unknown, :not_found}

      path ->
        timeout = Application.get_env(:helmsman_daemon, :codex_login_timeout_ms, 10_000)

        case Exec.command([path, "login", "status"], env: env, timeout: timeout) do
          {:ok, _} -> {:ok, :login}
          {:error, {{:exit_status, 256}, _}} -> {:error, :none}
          {:error, {{:exit_status, status}, _}} -> {:unknown, {:exit, div(status, 256)}}
          {:error, {:timeout, _}} -> {:unknown, :timeout}
          {:error, {:output_limit, _}} -> {:unknown, :output_limit}
          _ -> {:unknown, :command_failed}
        end
    end
  end
end
