defmodule HelmsmanDaemon.LocalRepos do
  @moduledoc """
  Machine-side local repositories (`[[local_repositories]]` in `config.toml`).

  Paths come only from this file; the server only ever names a repository.
  Every entry is validated independently: an invalid entry is still reported,
  marked unavailable with a reason, and never blocks the other entries.
  """
  alias HelmsmanDaemon.{AtomicFile, ConfigLock, Git, Paths}
  alias HelmsmanDaemon.LocalRepos.{Browse, ConfigFile, Roots, Web}
  alias HelmsmanProtocol.LocalRepository

  @name ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @max_reported 256

  def config_path, do: ConfigFile.path()

  @doc "Valid roots that allow web registration (`[%{label, real}]`), read again on every call."
  defdelegate roots, to: Roots, as: :valid

  @doc "Real path of an absolute path (symbolic links resolved, at most 40)."
  defdelegate real_path(path), to: Roots

  @doc "Repositories below the allowed roots, for `repo_browse`."
  defdelegate browse(opts \\ []), to: Browse, as: :run

  @doc "Executes a `repo_register` push; see `HelmsmanDaemon.LocalRepos.Web`."
  defdelegate register_from_web(push, opts \\ []), to: Web, as: :register

  @doc "Executes a `repo_remove` push; see `HelmsmanDaemon.LocalRepos.Web`."
  defdelegate remove_from_web(push, opts \\ []), to: Web, as: :remove
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
    do: %{
      name: raw["name"],
      path: raw["path"],
      workspaces: raw["workspaces"],
      added_from: raw["added_from"]
    }

  defp entry(_), do: %{name: nil, path: nil, workspaces: nil, added_from: nil}

  defp read_config, do: ConfigFile.read()

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
      added_from: entry[:added_from],
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
    if is_list(entry.workspaces) and Enum.all?(entry.workspaces, &(is_integer(&1) and &1 > 0)),
      do: path_problem(entry.path, opts),
      else: "workspaces must be a list of workspace IDs"
  end

  @doc "The path checks of one entry: nil when `path` is a usable repository root."
  def path_problem(path, opts \\ []) do
    cond do
      not is_binary(path) or Path.type(path) != :absolute ->
        "path must be absolute"

      inside_home?(path) ->
        "path is inside the daemon home directory"

      not File.dir?(path) ->
        "path does not exist or is not a directory"

      true ->
        repository_problem(path, opts)
    end
  end

  @doc false
  def inside_home?(path) do
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

  @doc false
  def git(args, cwd, opts) do
    context = Git.context(Paths.home(), nil, Keyword.take(opts, [:base_env, :executable]))

    case Git.run(args, cwd, context) do
      {:ok, output} -> {:ok, String.trim(output)}
      error -> error
    end
  end

  # Commands -----------------------------------------------------------------

  @doc "Adds an entry; slugs are mapped to IDs through `state/workspaces.json`."
  def add(path, name, slugs, opts \\ []) do
    locked(opts, fn ->
      with :ok <- check_name(name),
           {:ok, ids} <- slugs_to_ids(slugs),
           {:ok, text, decoded} <- read_config(),
           {:ok, current} <- raw_list(decoded),
           :ok <- unique(current, name) do
        entry = %{"name" => name, "path" => Path.expand(path), "workspaces" => ids}
        ConfigFile.write_local_repositories(text, decoded, current ++ [entry], opts)
      end
    end)
  end

  @doc "Removes the entry with this name."
  def remove(name, opts \\ []) do
    locked(opts, fn ->
      with {:ok, text, decoded} <- read_config(),
           {:ok, current} <- raw_list(decoded),
           {[_ | _], rest} <- Enum.split_with(current, &(&1["name"] == name)) do
        ConfigFile.write_local_repositories(text, decoded, rest, opts)
      else
        {[], _} -> {:error, "no local repository named #{name}"}
        error -> error
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

  defp raw_list(decoded), do: ConfigFile.local_repositories(decoded)

  defp unique(current, name) do
    if Enum.any?(current, &(&1["name"] == name)),
      do: {:error, "a local repository named #{name} already exists"},
      else: :ok
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

           web = if item.added_from == "web", do: " (added from the web)", else: ""

           "#{item.name}\t#{item.path}\tworkspaces: #{Enum.join(shared ++ ignored, ", ")}\t#{state}#{web}"
         end)}
    end
  end
end
