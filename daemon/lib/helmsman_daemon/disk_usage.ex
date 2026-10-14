defmodule HelmsmanDaemon.DiskUsage do
  @moduledoc "Disk usage of the daemon home's growing directories (shown by `daemon status`)."
  alias HelmsmanDaemon.{Env, Paths}

  @directories ~w(repos work scratch copilot-home cursor)

  @doc "`[{directory, bytes | nil}]`; nil when the directory does not exist."
  def measure(home \\ Paths.home()) do
    Enum.map(@directories, fn name ->
      path = Path.join(home, name)
      {name, if(File.dir?(path), do: size(path))}
    end)
  end

  defp size(path) do
    with du when is_binary(du) <- System.find_executable("du"),
         {output, 0} <- Env.cmd(du, ["-sk", path]),
         {kib, _} <- Integer.parse(output) do
      kib * 1024
    else
      _ -> walk(path)
    end
  end

  defp walk(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} -> names |> Enum.map(&walk(Path.join(path, &1))) |> Enum.sum()
          _ -> 0
        end

      {:ok, %File.Stat{size: size}} ->
        size

      _ ->
        0
    end
  end

  def format(nil), do: "-"
  def format(bytes) when bytes < 1024, do: "#{bytes} B"

  def format(bytes) do
    {value, unit} = scale(bytes / 1024, ~w(KB MB GB TB))
    "#{:erlang.float_to_binary(value, decimals: 1)} #{unit}"
  end

  defp scale(value, [unit]), do: {value, unit}
  defp scale(value, [unit | _]) when value < 1024, do: {value, unit}
  defp scale(value, [_ | units]), do: scale(value / 1024, units)
end
