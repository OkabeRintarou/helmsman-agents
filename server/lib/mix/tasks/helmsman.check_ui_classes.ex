defmodule Mix.Tasks.Helmsman.CheckUiClasses do
  @shortdoc "Checks HelmsmanWeb class/style attributes against the UI layering rules"

  @moduledoc """
  Enforces the UI layering rules of design D5b on `lib/helmsman_web/**` (`.ex` and `.heex`):

    1. Page layer (`lib/helmsman_web/live/**`): `class` attribute values must not use
       daisyUI component classes (`btn`, `badge-sm`, `hover:btn-primary`, ...). Those
       belong in `HelmsmanWeb.CoreComponents` / `HelmsmanWeb.Components.*`.
    2. Everywhere: `class` and `style` attribute values must not contain colour literals
       (`#fff`, `rgb(...)`, `oklch(...)`, ...) or Tailwind palette classes
       (`bg-blue-500`, `hover:text-red-600/50`, ...). Use the theme tokens instead.

  Both `attr="..."` and `attr={...}` are checked; for `{...}` every string literal in
  the expression is inspected.

      $ mix helmsman.check_ui_classes [--root DIR]

  `--root` defaults to the current project directory.
  """

  use Mix.Task
  use Boundary, top_level?: true, check: [in: false, out: false]

  @daisy_components ~w(btn input select textarea checkbox toggle radio fieldset label badge
                       dropdown tooltip loading kbd)
  @page_dir "lib/helmsman_web/live/"
  @attr_regex ~r/(?<![\w\-:.@])(class|style)\s*=\s*(?=["'{])/
  @colour_regex ~r/#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|oklch|oklab)\(/
  @palette_regex ~r/(?:^|[:!\[\s])((?:bg|text|border|ring|fill|stroke|outline|divide|decoration|accent|caret|from|via|to|shadow)-(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3}(?:\/\S+)?)/

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [root: :string])

    case violations(opts[:root] || File.cwd!()) do
      [] ->
        Mix.shell().info("UI class check OK")

      found ->
        Mix.raise(
          "UI class check failed:\n" <>
            Enum.map_join(found, "\n", fn {path, line, msg} -> "  #{path}:#{line}: #{msg}" end)
        )
    end
  end

  @doc "Returns all violations under `root` as `{relative_path, line, message}`, sorted."
  @spec violations(Path.t()) :: [{String.t(), pos_integer(), String.t()}]
  def violations(root) do
    root
    |> Path.join("lib/helmsman_web/**/*.{ex,heex}")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      path = Path.relative_to(file, root)
      page? = String.starts_with?(path, @page_dir)

      for {attr, line, strings} <- attributes(File.read!(file)),
          msg <- check(attr, strings, page?),
          do: {path, line, msg}
    end)
    |> Enum.sort()
  end

  defp attributes(content) do
    @attr_regex
    |> Regex.scan(content, return: :index)
    |> Enum.map(fn [{start, len}, {name_start, name_len}] ->
      rest = binary_slice(content, (start + len)..-1//1)
      line = content |> binary_part(0, start) |> :binary.matches("\n") |> length()
      {binary_part(content, name_start, name_len), line + 1, value_strings(rest)}
    end)
  end

  defp value_strings(<<q, rest::binary>>) when q in [?", ?'] do
    [rest |> :binary.split(<<q>>) |> hd()]
  end

  defp value_strings("{" <> rest) do
    rest
    |> :binary.matches("}")
    |> Enum.find_value([], fn {pos, _} ->
      case Code.string_to_quoted(binary_part(rest, 0, pos)) do
        {:ok, ast} -> ast |> Macro.prewalk([], &collect_string/2) |> elem(1)
        {:error, _} -> nil
      end
    end)
  end

  defp collect_string(node, acc) when is_binary(node), do: {node, [node | acc]}
  defp collect_string(node, acc), do: {node, acc}

  defp check(attr, strings, page?) do
    tokens = Enum.flat_map(strings, &String.split/1)

    daisy =
      if page? and attr == "class",
        do:
          for(t <- tokens, daisy?(t), do: "daisyUI component class #{inspect(t)} in page layer"),
        else: []

    colours =
      for s <- strings,
          [lit] <- Regex.scan(@colour_regex, s),
          do: "colour literal #{inspect(lit)} in #{attr} attribute"

    palette =
      for t <- tokens,
          Regex.match?(@palette_regex, t),
          do: "Tailwind palette class #{inspect(t)}; use theme tokens"

    Enum.uniq(daisy ++ colours ++ palette)
  end

  defp daisy?(token) do
    base = token |> String.split(":") |> List.last() |> String.trim("!")
    Enum.any?(@daisy_components, &(base == &1 or String.starts_with?(base, &1 <> "-")))
  end
end
