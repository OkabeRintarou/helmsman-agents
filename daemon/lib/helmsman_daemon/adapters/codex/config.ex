defmodule HelmsmanDaemon.Adapters.Codex.Config do
  @moduledoc false
  alias HelmsmanDaemon.Paths

  @blocked ~w(mcp_servers approval_policy approvals_reviewer sandbox_mode sandbox_workspace_write model model_reasoning_effort project_root_markers projects)

  def home, do: Path.join(Paths.home(), "codex")

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
