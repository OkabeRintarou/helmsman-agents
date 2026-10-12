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
          Map.has_key?(config, "project_root_markers") ->
            {:error, "#{path} sets project_root_markers, which Helmsman does not support"}

          is_map(config["mcp_servers"]) and map_size(config["mcp_servers"]) > 0 ->
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

  def filter(args), do: filter(args, [], [])
  defp filter([], kept, removed), do: {Enum.reverse(kept), Enum.reverse(removed)}

  defp filter([arg | rest], kept, removed) do
    [flag | inline] = String.split(arg, "=", parts: 2)

    if flag in ["-c", "--config", "--enable", "--disable"] do
      {value, rest} = value(inline, rest)
      key = if flag in ["-c", "--config"], do: config_key(value), else: nil

      keep_config(flag, arg, inline, value, key, rest, kept, removed)
    else
      filter(drop_value(rest), kept, [
        if(String.starts_with?(flag, "-"), do: flag, else: "positional argument") | removed
      ])
    end
  end

  defp keep_config(flag, arg, inline, value, key, rest, kept, removed) do
    if is_binary(value) and (is_nil(key) or allowed_key?(key)) do
      values = if inline == [], do: [value, flag], else: [arg]
      filter(rest, values ++ kept, removed)
    else
      filter(rest, kept, [key || flag | removed])
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

  defp allowed_key?(key) do
    key != "" and not Enum.any?(@blocked, &(key == &1 or String.starts_with?(key, &1 <> ".")))
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
