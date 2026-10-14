defmodule HelmsmanDaemon.LocalRepos.ConfigFile do
  @moduledoc """
  Reads `config.toml` and rewrites one part of it: the `[[local_repositories]]`
  blocks or the `[repos]` table.

  A rewrite drops the part's lines, appends a regenerated block with every key,
  and checks with `Toml.decode` that the result equals the expected value; any
  difference refuses the write. Callers hold `HelmsmanDaemon.ConfigLock`.
  """
  alias HelmsmanDaemon.{AtomicFile, Paths}

  @local_header ~r/\A\s*\[\[\s*local_repositories\s*\]\]\s*(#.*)?\z/
  @repos_header ~r/\A\s*\[\s*repos\s*\]\s*(#.*)?\z/
  @table ~r/\A\s*\[/
  @unsafe "config.toml has a layout this command cannot edit safely; edit it manually"

  def path, do: Path.join(Paths.home(), "config.toml")

  @doc "`{:ok, text, decoded}`; a missing file is empty."
  def read do
    case File.read(path()) do
      {:ok, text} ->
        case Toml.decode(text) do
          {:ok, decoded} -> {:ok, text, decoded}
          _ -> {:error, "config.toml is not valid TOML"}
        end

      {:error, :enoent} ->
        {:ok, "", %{}}

      {:error, reason} ->
        {:error, "could not read config.toml: #{:file.format_error(reason)}"}
    end
  end

  @doc "Raw `[[local_repositories]]` maps."
  def local_repositories(decoded) do
    case Map.get(decoded, "local_repositories", []) do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, "local_repositories in config.toml must be an array of tables"}
    end
  end

  @doc "Replaces every `[[local_repositories]]` block with `list`."
  def write_local_repositories(text, decoded, list, opts \\ []) do
    expected =
      if list == [],
        do: Map.delete(decoded, "local_repositories"),
        else: Map.put(decoded, "local_repositories", list)

    replace(
      text,
      @local_header,
      fn -> Enum.map_join(list, "\n", &block("[[local_repositories]]", &1)) end,
      expected,
      opts
    )
  end

  @doc "Replaces the `[repos]` table with `table` (all keys kept by the caller)."
  def write_repos(text, decoded, table, opts \\ []) do
    replace(
      text,
      @repos_header,
      fn -> block("[repos]", table) end,
      Map.put(decoded, "repos", table),
      opts
    )
  end

  defp replace(text, header, render, expected, opts) do
    kept =
      text
      |> String.split("\n")
      |> strip_blocks(header, [], false)
      |> Enum.join("\n")
      |> String.trim_trailing()

    new = Enum.join(Enum.reject([kept, render.()], &(&1 == "")), "\n\n") <> "\n"

    case Toml.decode(new) do
      {:ok, ^expected} ->
        case AtomicFile.write(path(), new, Keyword.take(opts, [:before_rename])) do
          :ok -> :ok
          _ -> {:error, "could not write #{path()}"}
        end

      _ ->
        {:error, @unsafe}
    end
  catch
    :unsupported_value -> {:error, @unsafe}
  end

  defp strip_blocks([], _header, acc, _in_block), do: Enum.reverse(acc)

  defp strip_blocks([line | rest], header, acc, in_block) do
    cond do
      Regex.match?(header, line) -> strip_blocks(rest, header, acc, true)
      in_block and Regex.match?(@table, line) -> strip_blocks(rest, header, [line | acc], false)
      in_block -> strip_blocks(rest, header, acc, true)
      true -> strip_blocks(rest, header, [line | acc], false)
    end
  end

  defp block(header, entry) do
    keys = Enum.map(Enum.sort(Map.keys(entry)), fn key -> "#{key} = #{value(entry[key])}" end)

    Enum.join([header | keys], "\n") <> "\n"
  end

  defp value(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &value/1) <> "]"
  defp value(int) when is_integer(int), do: Integer.to_string(int)
  defp value(true), do: "true"
  defp value(false), do: "false"
  defp value(text) when is_binary(text), do: "\"" <> escape(text) <> "\""
  defp value(_), do: throw(:unsupported_value)

  defp escape(text) do
    for <<char::utf8 <- text>>, into: "" do
      case char do
        ?\\ ->
          "\\\\"

        ?" ->
          "\\\""

        c when c < 0x20 or c == 0x7F ->
          "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")

        c ->
          <<c::utf8>>
      end
    end
  end
end
