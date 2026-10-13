defmodule HelmsmanDaemon.Adapters.Codex.Config do
  @moduledoc false
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.{Exec, Paths}

  @blocked ~w(mcp_servers approval_policy approvals_reviewer sandbox_mode sandbox_workspace_write model model_reasoning_effort project_root_markers projects)

  def home, do: Path.join(Paths.home(), "codex")

  # codex-cli 0.162.1 app-server does not consume OPENAI_API_KEY or CODEX_API_KEY
  # for its built-in provider. Custom providers are accepted independently.
  def provider_source(%{agent: %{provider_account: account}}, _home, _env)
      when not is_nil(account),
      do: {:ok, :account}

  def provider_source(spec, home, env) do
    args = if spec, do: elem(filter(spec.agent.custom_args), 0), else: []

    case effective_provider(args, home) do
      {:ok, "openai"} -> login_source(home, env)
      {:ok, provider} when is_binary(provider) and provider != "" -> {:ok, :custom_provider}
      _ -> {:unknown, :config}
    end
  end

  defp effective_provider(args, home) do
    case argument_provider(args, nil) do
      nil ->
        case File.read(Path.join(home, "config.toml")) do
          {:error, :enoent} -> {:ok, "openai"}
          {:ok, text} -> file_provider(text)
          _ -> {:unknown, :config}
        end

      provider ->
        provider
    end
  end

  defp file_provider(text) do
    case Toml.decode(text) do
      {:ok, config} -> {:ok, Map.get(config, "model_provider", "openai")}
      _ -> {:unknown, :config}
    end
  end

  defp argument_provider([], provider), do: provider

  defp argument_provider([arg | rest], provider) do
    [flag | inline] = String.split(arg, "=", parts: 2)
    {value, rest} = value(inline, rest)

    provider =
      if flag in ["-c", "--config"] and config_key(value) == "model_provider",
        do: parse_provider(value),
        else: provider

    argument_provider(rest, provider)
  end

  defp parse_provider(value) do
    case String.split(value, "=", parts: 2) do
      [_, raw] -> decode_provider(raw)
      _ -> {:unknown, :config}
    end
  end

  defp decode_provider(raw) do
    case Toml.decode("model_provider=" <> raw) do
      {:ok, %{"model_provider" => provider}} -> {:ok, provider}
      _ -> {:ok, String.trim(raw)}
    end
  end

  defp login_source(home, env) do
    env = Map.put(Map.new(env), "CODEX_HOME", home)

    case System.find_executable(Codex.executable()) do
      nil ->
        {:unknown, :not_found}

      path ->
        timeout = Application.get_env(:helmsman_daemon, :codex_login_timeout_ms, 10_000)

        case Exec.command([path, "login", "status"], env: env, timeout: timeout) do
          {:ok, _output} -> {:ok, :login}
          {:error, {{:exit_status, 256}, _output}} -> {:error, :none}
          {:error, {{:exit_status, status}, _output}} -> {:unknown, {:exit, div(status, 256)}}
          {:error, {:timeout, _output}} -> {:unknown, :timeout}
          {:error, {:output_limit, _output}} -> {:unknown, :output_limit}
          _ -> {:unknown, :command_failed}
        end
    end
  end

  def validate do
    path = Path.join(home(), "config.toml")

    case File.read(path) do
      {:error, :enoent} -> :ok
      {:error, _} -> {:error, "#{path} cannot be read"}
      {:ok, text} -> validate_toml(path, text)
    end
  end

  defp validate_toml(path, text) do
    case Toml.decode(text) do
      {:ok, config} ->
        cond do
          reserved_provider?(config) ->
            {:error,
             "#{path} defines model_providers.helmsman_account, which is reserved for Helmsman provider accounts; remove it"}

          Map.has_key?(config, "project_root_markers") ->
            {:error, "#{path} sets project_root_markers, which Helmsman does not support"}

          configured_mcp?(config["mcp_servers"]) ->
            names = config["mcp_servers"] |> Map.keys() |> Enum.sort() |> Enum.join(", ")

            {:error,
             "#{path} defines MCP servers (#{names}); remove them, Helmsman injects its own MCP servers per run"}

          Map.has_key?(config, "mcp_servers") and not is_map(config["mcp_servers"]) ->
            {:error, "#{path} defines invalid MCP servers"}

          true ->
            :ok
        end

      _ ->
        {:error, "#{path} is not valid TOML"}
    end
  end

  defp configured_mcp?(servers) when is_map(servers), do: map_size(servers) > 0
  defp configured_mcp?(_servers), do: false

  defp reserved_provider?(%{"model_providers" => providers}) when is_map(providers),
    do: Map.has_key?(providers, "helmsman_account")

  defp reserved_provider?(_config), do: false

  def cleanup_snapshots(home) do
    case File.rm_rf(Path.join(home, "shell_snapshots")) do
      {:ok, _} ->
        []

      {:error, _reason, _path} ->
        [{:status, %{level: :warning, message: "Could not remove old Codex shell snapshots"}}]
    end
  end

  def project_config(work_dir) do
    dirs = ancestors(Path.expand(work_dir), [])
    root = Enum.find(dirs, &File.exists?(Path.join(&1, ".git")))
    scope = if root, do: Enum.take_while(dirs, &(&1 != root)) ++ [root], else: [hd(dirs)]

    case Enum.find(scope, &File.exists?(Path.join([&1, ".codex", "config.toml"]))) do
      nil ->
        :ok

      dir ->
        relative = Path.relative_to(Path.join([dir, ".codex", "config.toml"]), work_dir)

        {:error,
         "#{relative} exists; Helmsman does not run Codex with project-level Codex config because it can add MCP servers or change the model provider. Remove it from the task workspace or repository"}
    end
  end

  defp ancestors(path, acc) do
    parent = Path.dirname(path)
    if parent == path, do: Enum.reverse([path | acc]), else: ancestors(parent, [path | acc])
  end

  def filter(args, account? \\ false), do: filter(args, [], [], account?)
  defp filter([], kept, removed, _account?), do: {Enum.reverse(kept), Enum.reverse(removed)}

  defp filter([arg | rest], kept, removed, account?) do
    [flag | inline] = String.split(arg, "=", parts: 2)

    if flag in ["-c", "--config", "--enable", "--disable"] do
      {value, rest} = value(inline, rest)
      key = if flag in ["-c", "--config"], do: config_key(value), else: nil

      keep_config({flag, arg, inline, value, key}, rest, kept, removed, account?)
    else
      filter(
        drop_value(rest),
        kept,
        [
          if(String.starts_with?(flag, "-"), do: flag, else: "positional argument") | removed
        ],
        account?
      )
    end
  end

  defp keep_config({flag, arg, inline, value, key}, rest, kept, removed, account?) do
    if is_binary(value) and (is_nil(key) or allowed_key?(key, account?)) do
      values = if inline == [], do: [value, flag], else: [arg]
      filter(rest, values ++ kept, removed, account?)
    else
      filter(rest, kept, [key || flag | removed], account?)
    end
  end

  defp value([value], rest), do: {value, rest}

  defp value([], [value | rest]) do
    if String.starts_with?(value, "-"), do: {nil, [value | rest]}, else: {value, rest}
  end

  defp value([], []), do: {nil, []}

  defp drop_value([value | rest]),
    do: if(String.starts_with?(value, "-"), do: [value | rest], else: rest)

  defp drop_value([]), do: []

  defp config_key(nil), do: "invalid config key"

  defp config_key(value) do
    value |> String.split("=", parts: 2) |> hd() |> String.replace(~r/[\s"']/, "")
  end

  defp allowed_key?(key, account?) do
    blocked =
      if account?,
        do: @blocked ++ ~w(model_provider model_providers),
        else: @blocked

    key != "" and
      not Enum.any?(blocked, &(key == &1 or String.starts_with?(key, &1 <> ".")))
  end

  def mcp(spec) do
    {extra, removed} =
      Enum.reduce(spec.agent.extra_mcp_servers, {%{}, []}, fn {name, entry}, {kept, removed} ->
        case convert(name, entry) do
          {:ok, converted} -> {Map.put(kept, name, converted), removed}
          :drop -> {kept, [name | removed]}
        end
      end)

    {Map.put(extra, "helmsman", %{
       "url" => spec.mcp.url,
       "bearer_token_env_var" => "HELMSMAN_RUN_TOKEN"
     }), Enum.sort(removed)}
  end

  defp convert(name, entry) when is_map(entry) do
    cond do
      String.downcase(name) == "helmsman" or entry["type"] == "sse" ->
        :drop

      is_binary(entry["command"]) ->
        {:ok,
         Map.take(entry, ["command", "cwd"])
         |> Map.put("args", entry["args"] || [])
         |> Map.put("env", entry["env"] || %{})}

      is_binary(entry["url"]) ->
        converted = Map.take(entry, ["url"])

        {:ok,
         if(entry["headers"],
           do: Map.put(converted, "http_headers", entry["headers"]),
           else: converted
         )}

      true ->
        :drop
    end
  end

  defp convert(_, _), do: :drop
end
