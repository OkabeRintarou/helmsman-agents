defmodule HelmsmanDaemon.Adapters.Codex.Config do
  @moduledoc false
  alias HelmsmanDaemon.Adapters.Codex.{Home, Source}

  @blocked ~w(mcp_servers approval_policy approvals_reviewer sandbox_mode sandbox_workspace_write model model_reasoning_effort project_root_markers projects profile profiles)

  def home do
    {:ok, {_mode, path}} = Home.resolve()
    path
  end

  def provider_source(spec, home, env), do: Source.check(spec, home, env)

  def read(home) do
    case File.read(Path.join(home, "config.toml")) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, text} ->
        case Toml.decode(text) do
          {:ok, values} -> {:ok, values}
          _ -> {:error, "#{Path.join(home, "config.toml")} is not valid TOML"}
        end

      _ ->
        {:error, "#{Path.join(home, "config.toml")} cannot be read"}
    end
  end

  def validate do
    with {:ok, location} <- Home.resolve(), do: validate(location)
  end

  def validate({mode, path}, version \\ "0.162.1") do
    with {:ok, _config} <- read_validated({mode, path}, version), do: :ok
  end

  def read_validated({mode, path}, version \\ "0.162.1") do
    with :ok <- directory(mode, path), {:ok, config} <- read(path) do
      config_path = Path.join(path, "config.toml")
      names = mcp_names(config)

      cond do
        reserved_provider?(config) ->
          {:error,
           "#{config_path} defines model_providers.helmsman_account, which is reserved for Helmsman provider accounts; remove it"}

        Map.has_key?(config, "project_root_markers") ->
          {:error, "#{config_path} sets project_root_markers, which Helmsman does not support"}

        Map.has_key?(config, "profile") ->
          {:error,
           "#{config_path} sets profile, which Codex #{version} no longer supports (legacy profiles); remove it, or move that profile to <name>.config.toml"}

        Enum.any?(names, &(String.downcase(&1) == "helmsman")) ->
          {:error,
           "#{config_path} defines an MCP server named helmsman; rename it (Helmsman injects its own server under that name for each run) or set [codex] home"}

        Map.has_key?(config, "mcp_servers") and not is_map(config["mcp_servers"]) ->
          {:error, "#{config_path} defines invalid MCP servers"}

        true ->
          {:ok, config}
      end
    end
  end

  def unchanged(location, original) do
    with {:ok, current} <- read_validated(location) do
      if current == original,
        do: :ok,
        else:
          {:error,
           "#{Path.join(elem(location, 1), "config.toml")} changed during the Codex provider check; retry the run"}
    end
  end

  defp directory(:user, path) do
    if File.dir?(path),
      do: :ok,
      else:
        {:error,
         "Codex home #{path} does not exist; sign in with codex login (or run codex once), or set [codex] home in #{Path.join(HelmsmanDaemon.Paths.home(), "config.toml")}"}
  end

  defp directory(:private, _path), do: :ok

  def mcp_names(config) do
    case config["mcp_servers"] do
      servers when is_map(servers) -> Map.keys(servers)
      _ -> []
    end
  end

  defp reserved_provider?(%{"model_providers" => providers}) when is_map(providers),
    do: Map.has_key?(providers, "helmsman_account")

  defp reserved_provider?(_config), do: false

  def cleanup_snapshots({:user, _home}), do: []

  def cleanup_snapshots({:private, home}) do
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

  def mcp(spec, user_names \\ []) do
    {extra, removed} =
      Enum.reduce(spec.agent.extra_mcp_servers, {%{}, []}, fn {name, entry}, {kept, removed} ->
        case convert(name, entry) do
          {:ok, converted} -> {Map.put(kept, name, converted), removed}
          :drop -> {kept, [name | removed]}
        end
      end)

    folded = MapSet.new(user_names, &String.downcase/1)
    collisions = Enum.filter(Map.keys(extra), &MapSet.member?(folded, String.downcase(&1)))
    disabled = Map.new(user_names, &{&1, %{"enabled" => false}})
    extra = extra |> Map.drop(collisions) |> Map.merge(disabled)

    {Map.put(extra, "helmsman", %{
       "url" => spec.mcp.url,
       "bearer_token_env_var" => "HELMSMAN_RUN_TOKEN"
     }), Enum.sort(removed ++ collisions)}
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
