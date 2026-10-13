defmodule HelmsmanDaemon.LocalRepos do
  @moduledoc """
  Machine-side local repositories (`[[local_repositories]]` in `config.toml`).

  Paths come only from this file; the server only ever names a repository.
  Every entry is validated independently: an invalid entry is still reported,
  marked unavailable with a reason, and never blocks the other entries.
  """
  alias HelmsmanDaemon.{AtomicFile, Git, Paths}
  alias HelmsmanProtocol.LocalRepository

  @name ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @header ~r/\A\s*\[\[\s*local_repositories\s*\]\]\s*(#.*)?\z/
  @table ~r/\A\s*\[/
  @max_reported 256

  def config_path, do: Path.join(Paths.home(), "config.toml")
  def served_path, do: Path.join(Paths.state(), "workspaces.json")

  def cache_path(name),
    do: Path.join([Paths.home(), "repos", "local", Paths.component!(name) <> ".git"])

  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc "Configured entries as raw maps, in file order."
  def entries do
    with {:ok, _text, decoded} <- read_config() do
      case Map.get(decoded, "local_repositories", []) do
        list when is_list(list) -> {:ok, Enum.map(list, &entry/1)}
        _ -> {:error, "local_repositories in config.toml must be an array of tables"}
      end
    end
  end

  defp entry(%{} = raw),
    do: %{name: raw["name"], path: raw["path"], workspaces: raw["workspaces"]}

  defp entry(_), do: %{name: nil, path: nil, workspaces: nil}

  defp read_config do
    case File.read(config_path()) do
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

  @doc "Workspaces this machine currently serves (`[%{id, slug}]`), or nil before the first join."
  def served do
    with {:ok, json} <- File.read(served_path()),
         {:ok, list} when is_list(list) <- Jason.decode(json) do
      for %{"id" => id, "slug" => slug} <- list,
          is_integer(id),
          is_binary(slug),
          do: %{id: id, slug: slug}
    else
      _ -> nil
    end
  end

  @doc "Atomically records the served workspaces from a join / sync reply's runtimes."
  def write_served(runtimes) do
    list =
      runtimes
      |> Enum.map(&%{"id" => &1.workspace_id, "slug" => &1.workspace_slug})
      |> Enum.uniq_by(& &1["id"])
      |> Enum.sort_by(& &1["id"])

    json = Jason.encode!(list)

    if File.read(served_path()) == {:ok, json} do
      :ok
    else
      Paths.private_dir!(Paths.state())
      AtomicFile.write(served_path(), json)
    end
  end

  @doc """
  Validates every entry. `served` is the list of served workspace IDs (nil = unknown):
  configured IDs outside it are ignored and listed in `ignored`.
  """
  def inspect_all(served, opts \\ []) do
    case entries() do
      {:ok, entries} ->
        names = Enum.frequencies_by(entries, & &1.name)
        Enum.map(entries, &check(&1, names, served, opts))

      {:error, _} ->
        []
    end
  end

  @doc "Report items for `join` / `sync`; entries without a reportable name or path are skipped."
  def report(served, opts \\ []) do
    served
    |> inspect_all(opts)
    |> Enum.flat_map(fn item ->
      case LocalRepository.new(%{
             name: item.name,
             path: item.path,
             workspaces: item.workspaces,
             default_branch: item.default_branch,
             available: item.available,
             unavailable_reason: item.unavailable_reason
           }) do
        {:ok, repo} -> [repo]
        _ -> []
      end
    end)
    |> Enum.take(@max_reported)
  end

  @doc """
  Re-reads the configuration for one access: the name must be configured once,
  valid, and still shared with `workspace_id`.
  """
  def resolve(name, workspace_id, opts \\ []) do
    with {:ok, entries} <- entries() do
      names = Enum.frequencies_by(entries, & &1.name)

      case Enum.find(entries, &(&1.name == name)) do
        nil -> {:error, "local repository #{name} is not configured on this machine"}
        entry -> shared(check(entry, names, nil, opts), workspace_id)
      end
    end
  end

  defp shared(%{available: false} = item, _workspace_id),
    do:
      {:error,
       "local repository #{item.name} is unavailable on this machine: #{item.unavailable_reason}"}

  defp shared(item, workspace_id) do
    if workspace_id in item.workspaces,
      do: {:ok, %{name: item.name, path: item.path}},
      else:
        {:error,
         "local repository #{item.name} is not shared with this workspace on this machine"}
  end

  defp check(entry, names, served, opts) do
    configured = if is_list(entry.workspaces), do: Enum.uniq(entry.workspaces), else: []
    {workspaces, ignored} = split_served(configured, served)

    base = %{
      name: entry.name,
      path: if(is_binary(entry.path), do: Path.expand(entry.path), else: entry.path),
      configured: configured,
      workspaces: workspaces,
      ignored: ignored,
      default_branch: nil,
      available: false,
      unavailable_reason: nil
    }

    case problem(entry, names, opts) do
      nil ->
        %{base | available: true, default_branch: default_branch(entry.path, opts)}

      reason ->
        %{base | unavailable_reason: reason}
    end
  end

  defp split_served(configured, nil), do: {configured, []}

  defp split_served(configured, served),
    do: Enum.split_with(configured, &(&1 in served))

  defp problem(entry, names, opts) do
    cond do
      not valid_name?(entry.name) ->
        "invalid name (lowercase letters, digits, - and _, at most 64 characters)"

      Map.get(names, entry.name, 0) > 1 ->
        "duplicate name on the machine"

      true ->
        layout_problem(entry, opts)
    end
  end

  defp layout_problem(entry, opts) do
    cond do
      not is_list(entry.workspaces) or
          not Enum.all?(entry.workspaces, &(is_integer(&1) and &1 > 0)) ->
        "workspaces must be a list of workspace IDs"

      not is_binary(entry.path) or Path.type(entry.path) != :absolute ->
        "path must be absolute"

      inside_home?(entry.path) ->
        "path is inside the daemon home directory"

      not File.dir?(entry.path) ->
        "path does not exist or is not a directory"

      true ->
        repository_problem(entry.path, opts)
    end
  end

  defp inside_home?(path) do
    home = Paths.home()
    expanded = Path.expand(path)
    expanded == home or String.starts_with?(expanded, home <> "/")
  end

  defp repository_problem(path, opts) do
    case git(["rev-parse", "--is-bare-repository", "--git-dir"], path, opts) do
      {:ok, output} ->
        case String.split(output, "\n", trim: true) do
          ["true", "."] -> nil
          ["true", _] -> "path is not the root of a git repository"
          ["false", _] -> worktree_root_problem(path, opts)
          _ -> "not a git repository"
        end

      {:error, {_, output}} ->
        if output =~ "dubious ownership",
          do: "repository is owned by another user (dubious ownership)",
          else: "not a git repository"
    end
  end

  defp worktree_root_problem(path, opts) do
    case git(["rev-parse", "--show-cdup"], path, opts) do
      {:ok, ""} -> nil
      _ -> "path is not the root of a git repository"
    end
  end

  defp default_branch(path, opts) do
    case git(["symbolic-ref", "--quiet", "--short", "HEAD"], path, opts) do
      {:ok, branch} when byte_size(branch) in 1..255 -> branch
      _ -> nil
    end
  end

  defp git(args, cwd, opts) do
    context = Git.context(Paths.home(), nil, Keyword.take(opts, [:base_env, :executable]))

    case Git.run(args, cwd, context) do
      {:ok, output} -> {:ok, String.trim(output)}
      error -> error
    end
  end

  # Commands -----------------------------------------------------------------

  @doc "Adds an entry; slugs are mapped to IDs through `state/workspaces.json`."
  def add(path, name, slugs, opts \\ []) do
    with :ok <- check_name(name),
         {:ok, ids} <- slugs_to_ids(slugs),
         {:ok, text, decoded} <- read_config(),
         {:ok, current} <- raw_list(decoded),
         :ok <- unique(current, name) do
      entry = %{"name" => name, "path" => Path.expand(path), "workspaces" => ids}
      rewrite(text, decoded, current ++ [entry], opts)
    end
  end

  @doc "Removes the entry with this name."
  def remove(name, opts \\ []) do
    with {:ok, text, decoded} <- read_config(),
         {:ok, current} <- raw_list(decoded) do
      case Enum.split_with(current, &(&1["name"] == name)) do
        {[], _} -> {:error, "no local repository named #{name}"}
        {_, rest} -> rewrite(text, decoded, rest, opts)
      end
    end
  end

  defp check_name(name) do
    if valid_name?(name),
      do: :ok,
      else:
        {:error,
         "invalid name #{inspect(name)}: use lowercase letters, digits, - and _ (at most 64)"}
  end

  defp slugs_to_ids([]), do: {:error, "give at least one --workspace"}

  defp slugs_to_ids(slugs) do
    case served() do
      nil ->
        {:error,
         "#{served_path()} not found; start the daemon once so it learns the workspaces it serves"}

      served ->
        Enum.reduce_while(Enum.uniq(slugs), {:ok, []}, &slug_to_id(&1, &2, served))
    end
  end

  defp slug_to_id(slug, {:ok, ids}, served) do
    case Enum.find(served, &(&1.slug == slug)) do
      nil -> {:halt, {:error, "workspace #{slug} is not served by this daemon; check the slug"}}
      %{id: id} -> {:cont, {:ok, ids ++ [id]}}
    end
  end

  defp raw_list(decoded) do
    case Map.get(decoded, "local_repositories", []) do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, "local_repositories in config.toml must be an array of tables"}
    end
  end

  defp unique(current, name) do
    if Enum.any?(current, &(&1["name"] == name)),
      do: {:error, "a local repository named #{name} already exists"},
      else: :ok
  end

  defp rewrite(text, decoded, list, opts) do
    write(text, decoded, list, opts)
  catch
    :unsupported_value ->
      {:error, "config.toml has a layout this command cannot edit safely; edit it manually"}
  end

  defp write(text, decoded, list, opts) do
    kept =
      text
      |> String.split("\n")
      |> strip_blocks([], false)
      |> Enum.join("\n")
      |> String.trim_trailing()

    blocks = Enum.map_join(list, "\n", &block/1)
    new = Enum.join(Enum.reject([kept, blocks], &(&1 == "")), "\n\n") <> "\n"

    expected =
      if list == [],
        do: Map.delete(decoded, "local_repositories"),
        else: Map.put(decoded, "local_repositories", list)

    case Toml.decode(new) do
      {:ok, ^expected} ->
        case AtomicFile.write(config_path(), new, Keyword.take(opts, [:before_rename])) do
          :ok -> :ok
          _ -> {:error, "could not write #{config_path()}"}
        end

      _ ->
        {:error, "config.toml has a layout this command cannot edit safely; edit it manually"}
    end
  end

  defp strip_blocks([], acc, _in_block), do: Enum.reverse(acc)

  defp strip_blocks([line | rest], acc, in_block) do
    cond do
      Regex.match?(@header, line) -> strip_blocks(rest, acc, true)
      in_block and Regex.match?(@table, line) -> strip_blocks(rest, [line | acc], false)
      in_block -> strip_blocks(rest, acc, true)
      true -> strip_blocks(rest, [line | acc], false)
    end
  end

  defp block(entry) do
    keys = Enum.map(Enum.sort(Map.keys(entry)), fn key -> "#{key} = #{value(entry[key])}" end)

    Enum.join(["[[local_repositories]]" | keys], "\n") <> "\n"
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

  @doc "Lines for `helmsman repos list`."
  def list_lines(opts \\ []) do
    served = served()
    ids = if served, do: Enum.map(served, & &1.id), else: nil
    slugs = Map.new(served || [], &{&1.id, &1.slug})

    case entries() do
      {:error, reason} ->
        {:error, reason}

      {:ok, []} ->
        {:ok, ["No local repositories"]}

      {:ok, _} ->
        {:ok,
         Enum.map(inspect_all(ids, opts), fn item ->
           shared = Enum.map(item.workspaces, &Map.get(slugs, &1, Integer.to_string(&1)))
           ignored = Enum.map(item.ignored, &"#{&1} (not served by this daemon)")

           state =
             if item.available, do: "available", else: "unavailable: #{item.unavailable_reason}"

           "#{item.name}\t#{item.path}\tworkspaces: #{Enum.join(shared ++ ignored, ", ")}\t#{state}"
         end)}
    end
  end
end
