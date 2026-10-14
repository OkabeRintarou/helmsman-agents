defmodule HelmsmanDaemon.LocalRepos.Roots do
  @moduledoc """
  Roots that allow web registration: `[repos] allowed_roots` in `config.toml`.

  Every call re-reads the file; nothing is cached. A malformed `[repos]` means
  no roots (web registration off) and never stops the daemon. Only the machine
  owner changes the list, with `helmsman repos roots add | remove`.
  """
  alias HelmsmanDaemon.{ConfigLock, Paths}
  alias HelmsmanDaemon.LocalRepos.ConfigFile

  @max_roots 16
  @max_links 40

  @doc """
  Real path of an absolute path: symbolic links are resolved one component at
  a time, at most 40 in total; the result has no `.` or `..` components.
  """
  def real_path(path) when is_binary(path) do
    if Path.type(path) == :absolute,
      do: walk(String.split(path, "/", trim: true), "/", 0),
      else: {:error, :enoent}
  end

  defp walk([], acc, _links), do: {:ok, acc}
  defp walk(["." | rest], acc, links), do: walk(rest, acc, links)
  defp walk([".." | rest], acc, links), do: walk(rest, Path.dirname(acc), links)

  defp walk([segment | rest], acc, links) do
    candidate = Path.join(acc, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} when links >= @max_links ->
        {:error, :eloop}

      {:ok, %File.Stat{type: :symlink}} ->
        follow(candidate, rest, acc, links)

      {:ok, _} ->
        walk(rest, candidate, links)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow(link, rest, acc, links) do
    with {:ok, target} <- :file.read_link_all(link) do
      target = if is_list(target), do: IO.chardata_to_string(target), else: target
      base = if String.starts_with?(target, "/"), do: "/", else: acc
      walk(String.split(target, "/", trim: true) ++ rest, base, links + 1)
    end
  end

  @doc "Valid roots in configuration order: `[%{label, real}]`."
  def valid do
    case ConfigFile.read() do
      {:ok, _text, decoded} -> valid(decoded)
      {:error, _} -> []
    end
  end

  @doc "Valid roots of an already decoded configuration."
  def valid(decoded) do
    case inspect_all(decoded) do
      {:ok, items} -> for %{problem: nil} = item <- items, do: Map.take(item, [:label, :real])
      {:error, _} -> []
    end
  end

  @doc """
  Every configured item with its real path or the reason it is ignored:
  `{:ok, [%{label, real, problem}]}`, or `{:error, reason}` when `[repos]` is
  malformed (then there are no roots at all).
  """
  def inspect_all(decoded) do
    with {:ok, labels} <- labels(decoded) do
      home = home_real()

      {items, _seen} = Enum.map_reduce(labels, %{}, &first_of_each(check(&1, home), &2))
      {:ok, items}
    end
  end

  # Items with the same real path keep the first.
  defp first_of_each(item, seen) do
    case {item.problem, Map.fetch(seen, item.real)} do
      {nil, {:ok, first}} -> {%{item | problem: "same directory as #{first}"}, seen}
      {nil, :error} -> {item, Map.put(seen, item.real, item.label)}
      _ -> {item, seen}
    end
  end

  defp labels(decoded) do
    case Map.get(decoded, "repos") do
      nil -> {:ok, []}
      table when is_map(table) -> table_labels(table)
      _ -> {:error, "[repos] in config.toml must be a table"}
    end
  end

  defp table_labels(table) do
    case Map.get(table, "allowed_roots") do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        cond do
          not Enum.all?(list, &is_binary/1) ->
            {:error, "allowed_roots in config.toml must be an array of strings"}

          length(list) > @max_roots ->
            {:error, "allowed_roots in config.toml has more than #{@max_roots} entries"}

          true ->
            {:ok, list}
        end

      _ ->
        {:error, "allowed_roots in config.toml must be an array of strings"}
    end
  end

  @doc "Absolute path of a label: `~` and `~/…` use the user's home; nil if neither absolute nor `~`."
  def expand("~"), do: user_home()
  def expand("~/" <> rest), do: Path.join(user_home(), rest)

  def expand(label) do
    if Path.type(label) == :absolute and String.valid?(label), do: label, else: nil
  end

  # `$HOME` of this process (what the VM's own home is taken from at start).
  defp user_home do
    case System.get_env("HOME") do
      home when is_binary(home) and home != "" -> home
      _ -> System.user_home!()
    end
  end

  # A directory given on the command line: `~` forms as above, others expanded.
  defp expand_dir(dir), do: Path.expand(expand(dir) || dir)

  defp check(label, home) do
    item = %{label: label, real: nil, problem: nil}

    with {:ok, path} <- absolute(label),
         {:ok, real} <- resolve(path),
         :ok <- not_slash(real),
         :ok <- outside_home(real, home) do
      %{item | real: real}
    else
      {:error, problem} -> %{item | problem: problem}
    end
  end

  defp absolute(label) do
    if String.contains?(label, <<0>>),
      do: {:error, "must be absolute or start with ~"},
      else:
        if(path = expand(label),
          do: {:ok, path},
          else: {:error, "must be absolute or start with ~"}
        )
  end

  defp resolve(path) do
    case real_path(path) do
      {:error, :eloop} ->
        {:error, "too many symbolic links"}

      {:ok, real} ->
        if File.dir?(real),
          do: {:ok, real},
          else: {:error, "does not exist or is not a directory"}

      {:error, _} ->
        {:error, "does not exist or is not a directory"}
    end
  end

  defp not_slash("/"), do: {:error, "cannot be /"}
  defp not_slash(_), do: :ok

  defp outside_home(real, home) do
    if real == home or String.starts_with?(real, home <> "/"),
      do: {:error, "inside the daemon home directory"},
      else: :ok
  end

  @doc "Real path of the daemon home (its expanded path when it cannot be resolved)."
  def home_real do
    case real_path(Paths.home()) do
      {:ok, real} -> real
      _ -> Paths.home()
    end
  end

  # Commands -----------------------------------------------------------------

  @doc "Lines for `helmsman repos roots`."
  def lines do
    with {:ok, _text, decoded} <- ConfigFile.read(),
         {:ok, items} <- inspect_all(decoded) do
      listed = if items == [], do: ["No allowed roots"], else: Enum.map(items, &line/1)
      enabled = Enum.any?(items, &is_nil(&1.problem))
      listed ++ ["Web registration: #{if enabled, do: "enabled", else: "disabled"}"]
    else
      {:error, reason} -> [reason <> "; ignoring all allowed roots", "Web registration: disabled"]
    end
  end

  defp line(%{label: label, problem: nil, real: real}), do: "#{label}\t#{real}"
  defp line(%{label: label, problem: problem}), do: "#{label}\tignored: #{problem}"

  @doc "`helmsman repos roots add`: validates and appends the expanded absolute path."
  def add(dir, opts \\ []) do
    locked(opts, fn ->
      expanded = expand_dir(dir)

      with {:ok, text, decoded} <- ConfigFile.read(),
           {:ok, table, current} <- table(decoded),
           {:ok, items} <- inspect_all(decoded),
           %{problem: nil, real: real} <- check(expanded, home_real()),
           :ok <- not_present(items, current, expanded, real),
           :ok <- room(current) do
        ConfigFile.write_repos(
          text,
          decoded,
          Map.put(table, "allowed_roots", current ++ [expanded]),
          opts
        )
      else
        %{problem: problem} -> {:error, "#{dir} cannot be an allowed root: #{problem}"}
        error -> error
      end
    end)
  end

  @doc "`helmsman repos roots remove`: removes the items written as `dir` or expanding to it."
  def remove(dir, opts \\ []) do
    locked(opts, fn ->
      expanded = expand_dir(dir)

      with {:ok, text, decoded} <- ConfigFile.read(),
           {:ok, table, current} <- table(decoded),
           rest when rest != current <-
             Enum.reject(current, &(&1 == dir or expand(&1) == expanded)) do
        ConfigFile.write_repos(text, decoded, Map.put(table, "allowed_roots", rest), opts)
      else
        {:error, _} = error -> error
        _unchanged -> {:error, "#{dir} is not in allowed_roots"}
      end
    end)
  end

  defp locked(opts, fun) do
    timeout = Keyword.get(opts, :config_lock_timeout_ms, ConfigLock.timeout_ms())

    case ConfigLock.with_lock(fun, timeout_ms: timeout) do
      {:ok, result} -> result
      {:error, :timeout} -> {:error, ConfigLock.locked_message()}
      {:error, :unavailable} -> {:error, "could not lock config.toml"}
    end
  end

  defp table(decoded) do
    case labels(decoded) do
      {:ok, labels} -> {:ok, Map.get(decoded, "repos", %{}), labels}
      {:error, reason} -> {:error, reason <> "; edit it manually"}
    end
  end

  defp not_present(items, current, expanded, real) do
    cond do
      Enum.any?(current, &(expand(&1) == expanded)) ->
        {:error, "#{expanded} is already in allowed_roots"}

      item = Enum.find(items, &(&1.problem == nil and &1.real == real)) ->
        {:error, "#{expanded} is already allowed as #{item.label}"}

      true ->
        :ok
    end
  end

  defp room(current) do
    if length(current) < @max_roots,
      do: :ok,
      else: {:error, "allowed_roots already has #{@max_roots} entries"}
  end
end
