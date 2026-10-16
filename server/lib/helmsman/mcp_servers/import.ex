defmodule Helmsman.McpServers.Import do
  @moduledoc "Parse pasted CLI configuration without storing or logging its text."
  alias Helmsman.McpServers.Entry

  def parse(text, name \\ "imported") when is_binary(text) do
    with {:ok, entries} <- decode(String.trim(text), name) do
      {:ok,
       Enum.map(entries, fn {name, config} ->
         {config, warnings} = normalize(config)

         errors =
           case Entry.validate(%{name => config}) do
             {:ok, _} -> []
             {:error, errors} -> errors
           end

         %{name: name, config: config, warnings: Enum.uniq(warnings), errors: errors}
       end)}
    end
  rescue
    _ -> {:error, :unrecognized_format}
  end

  defp decode("{" <> _ = text, name) do
    case Jason.decode(text) do
      {:ok, %{"mcpServers" => entries}} when is_map(entries) -> {:ok, entries}
      {:ok, %{"servers" => entries}} when is_map(entries) -> {:ok, entries}
      {:ok, entry} when is_map(entry) -> {:ok, %{name => entry}}
      _ -> {:error, :unrecognized_format}
    end
  end

  defp decode("[" <> _ = text, _) do
    case Toml.decode(text) do
      {:ok, %{"mcp_servers" => servers}} ->
        {:ok, Map.new(servers, fn {name, config} -> {name, codex(config)} end)}

      _ ->
        {:error, :unrecognized_format}
    end
  end

  defp decode(text, _) do
    case OptionParser.split(text) do
      ["claude", "mcp", "add-json", name, json] -> decode_json(name, json)
      [cli, "mcp", "add" | args] when cli in ["claude", "codex"] -> command(args, cli)
      _ -> {:error, :unrecognized_format}
    end
  end

  defp decode_json(name, json) do
    case Jason.decode(json) do
      {:ok, entry} when is_map(entry) -> {:ok, %{name => entry}}
      _ -> {:error, :unrecognized_format}
    end
  end

  defp command(args, cli) do
    {positionals, opts, trailing} = options(args, [], %{"env" => %{}, "headers" => %{}}, [])

    case positionals ++ trailing do
      [name, target | rest] ->
        type =
          opts["type"] ||
            if(String.starts_with?(target, ["https://", "http://"]), do: "http", else: "stdio")

        config = Map.put(opts, "type", type)

        config =
          if type == "stdio",
            do: Map.merge(config, %{"command" => target, "args" => rest}),
            else: Map.put(config, "url", target)

        if cli == "codex" and type != "stdio",
          do: {:error, :unrecognized_format},
          else: {:ok, %{name => config}}

      _ ->
        {:error, :unrecognized_format}
    end
  end

  defp options([], positions, opts, trailing), do: {Enum.reverse(positions), opts, trailing}
  defp options(["--" | rest], positions, opts, _), do: {Enum.reverse(positions), opts, rest}

  defp options([flag, value | rest], positions, opts, trailing)
       when flag in ["--transport", "--scope", "-s", "-e", "--env", "-H", "--header"] do
    opts =
      case flag do
        "--transport" -> Map.put(opts, "type", value)
        f when f in ["--scope", "-s"] -> opts
        f when f in ["-e", "--env"] -> put_pair(opts, "env", value, "=")
        _ -> put_pair(opts, "headers", value, ":")
      end

    options(rest, positions, opts, trailing)
  end

  defp options([arg | rest], positions, opts, trailing),
    do: options(rest, [arg | positions], opts, trailing)

  defp put_pair(opts, key, value, separator) do
    case String.split(value, separator, parts: 2) do
      [name, val] -> Map.update!(opts, key, &Map.put(&1, String.trim(name), String.trim(val)))
      _ -> opts
    end
  end

  defp codex(config) do
    env =
      Map.merge(config["env"] || %{}, Map.new(config["env_vars"] || [], &{&1, "${env:#{&1}}"}))

    headers =
      Map.merge(
        config["http_headers"] || %{},
        Map.new(config["env_http_headers"] || %{}, fn {k, v} -> {k, "${env:#{v}}"} end)
      )

    headers =
      if config["bearer_token_env_var"],
        do: Map.put(headers, "Authorization", "Bearer ${env:#{config["bearer_token_env_var"]}}"),
        else: headers

    config
    |> Map.drop(~w(env_vars env_http_headers bearer_token_env_var http_headers))
    |> Map.put("env", env)
    |> Map.put("headers", headers)
  end

  defp normalize(value) when is_map(value) do
    Enum.reduce(value, {%{}, []}, fn {k, v}, {acc, warnings} ->
      {v, more} = normalize(v)
      {Map.put(acc, k, v), warnings ++ more}
    end)
  end

  defp normalize(value) when is_list(value) do
    {values, warnings} =
      Enum.reduce(value, {[], []}, fn v, {acc, warnings} ->
        {v, more} = normalize(v)
        {[v | acc], warnings ++ more}
      end)

    {Enum.reverse(values), warnings}
  end

  defp normalize(value) when is_binary(value) do
    warnings =
      if Regex.match?(~r/\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\}/, value),
        do: [:default_ignored],
        else: []

    warnings =
      if String.contains?(value, "${input:"), do: warnings ++ [:input_unsupported], else: warnings

    value = Regex.replace(~r/\$\{input:[^}]*\}/, value, "")

    value =
      Regex.replace(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-[^}]*)?\}/, value, fn _, name ->
        "${env:#{name}}"
      end)

    {value, warnings}
  end

  defp normalize(value), do: {value, []}
end
