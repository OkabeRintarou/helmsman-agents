defmodule HelmsmanDaemon.Adapters.Copilot.Home do
  @moduledoc false
  alias HelmsmanDaemon.Paths

  @configuration ~w(mcp-config.json mcp-config mcp-oauth-config hooks agents skills instructions copilot-instructions.md lsp-config.json providers.json permissions-config.json)
  @generated_keys ~w(firstLaunchAt)

  def validate do
    home = Paths.copilot_home()
    names = Enum.filter(@configuration, &exists?(Path.join(home, &1)))
    names = names ++ plugins(home) ++ inline_configuration(home)

    if names == [],
      do: {:ok, home},
      else:
        {:error,
         "Copilot home has user configuration (#{Enum.join(names, ", ")}); Helmsman needs it empty of configuration"}
  end

  defp exists?(path), do: match?({:ok, _}, File.lstat(path))

  defp plugins(home) do
    case File.ls(Path.join(home, "installed-plugins")) do
      {:ok, []} -> []
      {:error, :enoent} -> []
      _ -> ["installed-plugins"]
    end
  end

  defp inline_configuration(home) do
    Enum.flat_map(~w(config.json settings.json), fn name ->
      case File.read(Path.join(home, name)) do
        {:ok, text} ->
          describe_configuration(name, configuration_keys(text))

        {:error, :enoent} ->
          []

        _ ->
          [name]
      end
    end)
  end

  defp describe_configuration(_name, []), do: []
  defp describe_configuration(name, [nil]), do: [name]
  defp describe_configuration(name, keys), do: [name <> ": " <> Enum.join(keys, ", ")]

  defp configuration_keys(text) do
    text =
      text
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "//"))
      |> Enum.join("\n")

    case JSON.decode(text) do
      {:ok, config} when is_map(config) ->
        config
        |> Enum.reject(&allowed_setting?/1)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      _ ->
        [nil]
    end
  end

  defp allowed_setting?({key, _}) when key in @generated_keys, do: true
  defp allowed_setting?({"powershellFlags", _}), do: false
  defp allowed_setting?({_, value}), do: value in [nil, false, "", [], %{}]
end
