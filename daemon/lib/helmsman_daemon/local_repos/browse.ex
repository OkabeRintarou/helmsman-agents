defmodule HelmsmanDaemon.LocalRepos.Browse do
  @moduledoc """
  Lists git repositories below the allowed roots for `repo_browse`.

  Breadth-first from each root's real path, never following symbolic links,
  never entering hidden, unreadable or non-UTF-8 directories or a repository,
  at most 4 levels deep. All roots together stop after 10 000 directories,
  200 candidates or 5 seconds (`truncated`); the time budget covers the whole
  request, from reading the configuration to the last directory entry. No git command runs: a candidate
  is only checked when it is registered. Each candidate carries only its root
  label, relative path, a suggested name and the name it is registered as.
  """
  alias HelmsmanDaemon.LocalRepos
  alias HelmsmanDaemon.LocalRepos.{ConfigFile, Roots}

  @max_depth 4
  @control ~r/[\x00-\x1F\x7F]/

  @doc """
  `{:ok, %{roots, repositories, truncated}}`, `{:error, :disabled}` without a
  valid root, or `{:error, :busy}` when the budget ran out before the roots
  were resolved.

  Every file system call (configuration, roots, listing, `lstat`, real paths of
  configured entries) runs in a linked worker that streams candidates to the
  caller. The worker checks the deadline before each directory entry; the
  caller kills it at the deadline in any case (a blocked listing) and answers
  with the candidates found so far, `truncated: true`.
  """
  def run(opts \\ []) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :browse_time_limit_ms, 5_000)

    tag = make_ref()
    parent = self()
    pid = spawn_link(fn -> worker(parent, tag, deadline, opts) end)
    monitor = Process.monitor(pid)

    collect(%{pid: pid, monitor: monitor, tag: tag, deadline: deadline}, %{
      roots: nil,
      entries: [],
      found: []
    })
  end

  defp collect(run, acc) do
    tag = run.tag
    remaining = max(run.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^tag, message} ->
        collect(run, collected(message, acc))

      {^tag, :done, truncated} ->
        Process.demonitor(run.monitor, [:flush])
        finish(acc, truncated)
    after
      remaining ->
        Process.unlink(run.pid)
        Process.exit(run.pid, :kill)
        finish(drain(run, acc), true)
    end
  end

  # Messages the worker sent before it died arrive before its DOWN.
  defp drain(run, acc) do
    tag = run.tag
    monitor = run.monitor

    receive do
      {^tag, message} -> drain(run, collected(message, acc))
      {^tag, :done, _} -> drain(run, acc)
      {:DOWN, ^monitor, :process, _, _} -> acc
    end
  end

  defp collected({:setup, roots, entries}, acc), do: %{acc | roots: roots, entries: entries}
  defp collected({:found, found}, acc), do: %{acc | found: [found | acc.found]}

  defp finish(%{roots: nil}, _truncated), do: {:error, :busy}
  defp finish(%{roots: []}, _truncated), do: {:error, :disabled}

  defp finish(acc, truncated) do
    order = acc.roots |> Enum.with_index() |> Map.new(fn {root, index} -> {root.label, index} end)

    found =
      Enum.sort_by(acc.found, fn {root, path, _real} -> {Map.fetch!(order, root.label), path} end)

    entries = acc.entries

    {repositories, _taken} =
      Enum.map_reduce(found, MapSet.new(entries, & &1.name), &candidate(&1, &2, entries))

    {:ok,
     %{roots: Enum.map(acc.roots, & &1.label), repositories: repositories, truncated: truncated}}
  end

  defp worker(parent, tag, deadline, opts) do
    Keyword.get(opts, :browse_on_start, fn -> :ok end).()

    {decoded, roots} =
      case ConfigFile.read() do
        {:ok, _text, decoded} -> {decoded, Roots.valid(decoded)}
        {:error, _} -> {%{}, []}
      end

    entries = if roots == [], do: [], else: configured(decoded)
    send(parent, {tag, {:setup, roots, entries}})

    limits = %{
      dirs: Keyword.get(opts, :browse_max_dirs, 10_000),
      candidates: Keyword.get(opts, :browse_max_candidates, 200),
      deadline: deadline,
      on_visit: Keyword.get(opts, :browse_on_visit, fn -> :ok end),
      on_list: Keyword.get(opts, :browse_on_list, fn _dir -> :ok end),
      emit: &send(parent, {tag, {:found, &1}})
    }

    state =
      Enum.reduce_while(roots, %{visited: 0, found: 0, truncated: false}, fn root, state ->
        state = scan_root(root, state, limits)
        if state.truncated, do: {:halt, state}, else: {:cont, state}
      end)

    send(parent, {tag, :done, state.truncated})
  end

  defp scan_root(root, state, limits) do
    case visit(state, limits) do
      {:stop, state} ->
        state

      {:ok, state} ->
        if repository?(root.real),
          do: add(state, {root, ".", root.real}, limits),
          else: walk(:queue.from_list([{root.real, []}]), root, state, limits)
    end
  end

  defp walk(queue, root, state, limits) do
    case :queue.out(queue) do
      {:empty, _} ->
        state

      {{:value, {dir, segments}}, rest} ->
        case children(dir, segments, root, rest, state, limits) do
          {:stop, state} -> state
          {:ok, queue, state} -> walk(queue, root, state, limits)
        end
    end
  end

  defp children(dir, segments, root, queue, state, limits) do
    limits.on_list.(dir)

    # Raw names: a name that is not UTF-8 must be skipped, not fail the listing.
    case :file.list_dir_all(dir) do
      {:ok, names} ->
        names
        |> Enum.map(&if(is_list(&1), do: IO.chardata_to_string(&1), else: &1))
        |> Enum.sort()
        |> Enum.reduce_while({:ok, queue, state}, fn name, {:ok, queue, state} ->
          child(name, dir, segments, root, queue, state, limits)
        end)

      {:error, _} ->
        {:ok, queue, state}
    end
  end

  defp child(name, dir, segments, root, queue, state, limits) do
    path = Path.join(dir, name)

    with {:ok, state} <- in_time(state, limits),
         true <- listable?(name),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, state} <- visit(state, limits) do
      enter(path, segments ++ [name], root, queue, state, limits)
    else
      {:stop, state} -> {:halt, {:stop, state}}
      _ -> {:cont, {:ok, queue, state}}
    end
  end

  # A candidate is listed and not entered; other directories are queued above the depth limit.
  defp enter(path, segments, root, queue, state, limits) do
    cond do
      repository?(path) ->
        case add(state, {root, Enum.join(segments, "/"), path}, limits) do
          %{truncated: true} = state -> {:halt, {:stop, state}}
          state -> {:cont, {:ok, queue, state}}
        end

      length(segments) < @max_depth ->
        {:cont, {:ok, :queue.in({path, segments}, queue), state}}

      true ->
        {:cont, {:ok, queue, state}}
    end
  end

  defp listable?(name),
    do:
      not String.starts_with?(name, ".") and String.valid?(name) and
        not Regex.match?(@control, name)

  # Checked before every directory entry, files included.
  defp in_time(state, limits) do
    if System.monotonic_time(:millisecond) >= limits.deadline,
      do: {:stop, %{state | truncated: true}},
      else: {:ok, state}
  end

  defp visit(state, limits) do
    limits.on_visit.()

    with {:ok, state} <- in_time(state, limits) do
      if state.visited >= limits.dirs,
        do: {:stop, %{state | truncated: true}},
        else: {:ok, %{state | visited: state.visited + 1}}
    end
  end

  defp add(state, found, limits) do
    if state.found >= limits.candidates do
      %{state | truncated: true}
    else
      limits.emit.(found)
      %{state | found: state.found + 1}
    end
  end

  @doc "A work tree with a real `.git` (directory or gitfile), or a bare repository."
  def repository?(dir) do
    type(Path.join(dir, ".git")) in [:directory, :regular] or
      (type(Path.join(dir, "HEAD")) == :regular and type(Path.join(dir, "objects")) == :directory and
         type(Path.join(dir, "refs")) == :directory)
  end

  defp type(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} -> type
      _ -> nil
    end
  end

  defp configured(decoded) do
    case ConfigFile.local_repositories(decoded) do
      {:ok, list} ->
        for %{"name" => name} = entry <- list, is_binary(name) do
          %{name: name, real: real(entry["path"])}
        end

      _ ->
        []
    end
  end

  defp real(path) when is_binary(path) do
    case Roots.real_path(path) do
      {:ok, real} -> real
      _ -> nil
    end
  end

  defp real(_), do: nil

  defp candidate({root, path, real}, taken, entries) do
    registered = Enum.find(entries, &(&1.real == real))

    if registered && LocalRepos.valid_name?(registered.name) do
      {%{root: root.label, path: path, name: registered.name, registered_as: registered.name},
       taken}
    else
      base = if path == ".", do: Path.basename(root.real), else: Path.basename(path)
      name = unique(suggest(base), taken)
      {%{root: root.label, path: path, name: name, registered_as: nil}, MapSet.put(taken, name)}
    end
  end

  @doc "Suggested name for a directory name: lowercase, `[a-z0-9_-]`, at most 64 characters."
  def suggest(base) do
    name =
      base
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]/u, "-")
      |> String.replace(~r/\A[^a-z0-9]+/, "")
      |> binary_part_max(64)

    if name == "", do: "repo", else: name
  end

  defp unique(name, taken), do: unique(name, taken, 1)

  defp unique(name, taken, 1) do
    if MapSet.member?(taken, name), do: unique(name, taken, 2), else: name
  end

  defp unique(name, taken, n) do
    suffix = "-#{n}"
    candidate = binary_part_max(name, 64 - byte_size(suffix)) <> suffix
    if MapSet.member?(taken, candidate), do: unique(name, taken, n + 1), else: candidate
  end

  defp binary_part_max(text, max) when byte_size(text) <= max, do: text
  defp binary_part_max(text, max), do: binary_part(text, 0, max)
end
