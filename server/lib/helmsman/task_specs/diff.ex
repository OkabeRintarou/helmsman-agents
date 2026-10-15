defmodule Helmsman.TaskSpecs.Diff do
  @moduledoc """
  The line diff of two spec versions (`add-spec-workflow` decision 17).

  Files are compared by path: `added`, `removed`, `modified` or
  `unchanged`. A modified file is diffed by lines with
  `List.myers_difference/2` into unified hunks with 3 lines of context.
  Each file is computed in a task limited to 2 seconds; past it the
  file is `replaced` (with the line counts of both sides). Past 512 KB of
  diff text the remaining hunks are dropped and `truncated` is true.
  """

  @timeout 2_000
  @context 3
  @max_bytes 512 * 1024

  @type line :: {:eq | :del | :ins, String.t()}
  @type hunk :: %{
          old_start: non_neg_integer(),
          old_lines: non_neg_integer(),
          new_start: non_neg_integer(),
          new_lines: non_neg_integer(),
          lines: [line()]
        }
  @type file :: %{
          required(:path) => String.t(),
          required(:change) => :added | :removed | :modified | :replaced | :unchanged,
          required(:hunks) => [hunk()],
          optional(:old_lines) => non_neg_integer(),
          optional(:new_lines) => non_neg_integer()
        }

  @doc """
  Diffs `old` and `new` (`%{path => content}`). Returns `%{files,
  truncated}`, files sorted by path.
  """
  @spec run(%{String.t() => String.t()}, %{String.t() => String.t()}) ::
          %{files: [file()], truncated: boolean()}
  def run(old, new) do
    paths = (Map.keys(old) ++ Map.keys(new)) |> Enum.uniq() |> Enum.sort()
    hook = test_hook()

    {files, {_bytes, truncated}} =
      Enum.map_reduce(paths, {0, false}, fn path, {bytes, truncated} ->
        file = compare(path, old[path], new[path], hook, truncated)
        size = file_bytes(file)

        cond do
          truncated -> {file, {bytes, true}}
          bytes + size > @max_bytes -> {%{file | hunks: []}, {bytes, true}}
          true -> {file, {bytes + size, false}}
        end
      end)

    %{files: files, truncated: truncated}
  end

  defp compare(path, nil, new, _hook, truncated),
    do: whole(path, :added, [], split(new), truncated)

  defp compare(path, old, nil, _hook, truncated),
    do: whole(path, :removed, split(old), [], truncated)

  defp compare(path, same, same, _hook, _truncated),
    do: %{path: path, change: :unchanged, hunks: []}

  defp compare(path, _old, _new, _hook, true), do: %{path: path, change: :modified, hunks: []}

  defp compare(path, old, new, hook, false) do
    {a, b} = {split(old), split(new)}
    task = Task.async(fn -> hunks(a, b, hook, path) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, hunks} ->
        %{path: path, change: :modified, hunks: hunks}

      _timeout ->
        %{path: path, change: :replaced, hunks: [], old_lines: length(a), new_lines: length(b)}
    end
  end

  defp whole(path, change, _a, _b, true), do: %{path: path, change: change, hunks: []}

  defp whole(path, change, a, b, false) do
    lines = Enum.map(a, &{:del, &1}) ++ Enum.map(b, &{:ins, &1})

    hunk = %{
      old_start: if(a == [], do: 0, else: 1),
      old_lines: length(a),
      new_start: if(b == [], do: 0, else: 1),
      new_lines: length(b),
      lines: lines
    }

    %{path: path, change: change, hunks: if(lines == [], do: [], else: [hunk])}
  end

  defp split(content) do
    content
    |> String.split("\n")
    |> then(fn lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines end)
  end

  defp file_bytes(%{hunks: hunks}) do
    for %{lines: lines} <- hunks, {_op, text} <- lines, reduce: 0 do
      acc -> acc + byte_size(text) + 2
    end
  end

  @doc false
  # The unified hunks of two line lists.
  def hunks(a, b, hook \\ nil, path \\ nil) do
    if hook, do: hook.({:spec_diff, path})

    ops =
      a
      |> List.myers_difference(b)
      |> Enum.flat_map(fn {op, lines} -> Enum.map(lines, &{op, &1}) end)
      |> number()

    ops
    |> ranges()
    |> Enum.map(fn {from, to} -> hunk(Enum.slice(ops, from..to//1)) end)
  end

  # `{op, text, old_no, new_no}`: the 1-based line numbers before the line.
  defp number(ops) do
    {numbered, _} =
      Enum.map_reduce(ops, {1, 1}, fn {op, text}, {o, n} ->
        op = %{eq: :eq, del: :del, ins: :ins}[op]

        next =
          case op do
            :eq -> {o + 1, n + 1}
            :del -> {o + 1, n}
            :ins -> {o, n + 1}
          end

        {{op, text, o, n}, next}
      end)

    numbered
  end

  # Index ranges of the hunks: each change with its context, merged.
  defp ranges(ops) do
    last = length(ops) - 1

    ops
    |> Enum.with_index()
    |> Enum.filter(fn {{op, _, _, _}, _i} -> op != :eq end)
    |> Enum.map(fn {_op, i} -> {max(i - @context, 0), min(i + @context, last)} end)
    |> Enum.reduce([], fn
      {from, to}, [{pfrom, pto} | rest] when from <= pto + 1 -> [{pfrom, max(to, pto)} | rest]
      range, acc -> [range | acc]
    end)
    |> Enum.reverse()
  end

  defp hunk([{_op, _text, o, n} | _] = ops) do
    old = Enum.count(ops, fn {op, _, _, _} -> op != :ins end)
    new = Enum.count(ops, fn {op, _, _, _} -> op != :del end)

    %{
      old_start: if(old == 0, do: o - 1, else: o),
      old_lines: old,
      new_start: if(new == 0, do: n - 1, else: n),
      new_lines: new,
      lines: Enum.map(ops, fn {op, text, _, _} -> {op, text} end)
    }
  end

  # Tests make a file's diff slow: compiled in the test environment only.
  if Mix.env() == :test do
    defp test_hook do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook
        _ -> nil
      end
    end
  else
    defp test_hook, do: nil
  end
end
