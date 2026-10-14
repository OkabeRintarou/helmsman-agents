defmodule HelmsmanDaemon.LocalRepos.Web do
  @moduledoc """
  Registration and removal requested from the web (`repo_register` / `repo_remove`).

  The daemon trusts nothing from the server. Every check runs inside
  `HelmsmanDaemon.ConfigLock`, against the configuration and roots read again
  inside the lock; the written path is the real path computed there. Results
  are `:ok` or `{:error, code, message}` with a `HelmsmanProtocol.RepoRequestError`
  code.

  Options: `:lock` (module with `with_lock/2`, default `ConfigLock`),
  `:lock_timeout_ms`, `:before_lock` (test hook), `:trace` (called with each
  step name), `:now`, and the git options of `HelmsmanDaemon.LocalRepos`.
  """
  require Logger
  alias HelmsmanDaemon.{ConfigLock, LocalRepos}
  alias HelmsmanDaemon.LocalRepos.{ConfigFile, Roots}
  alias HelmsmanProtocol.RepoField

  @max_depth 4

  def register(push, opts \\ []) do
    locked(push, opts, fn -> do_register(push, opts) end)
    |> log(push, :register, "registered")
  end

  def remove(push, opts \\ []) do
    locked(push, opts, fn -> do_remove(push, opts) end)
    |> log(push, :remove, "removed")
  end

  defp locked(_push, opts, fun) do
    Keyword.get(opts, :before_lock, fn -> :ok end).()
    lock = Keyword.get(opts, :lock, ConfigLock)

    case lock.with_lock(fun,
           timeout_ms: Keyword.get(opts, :lock_timeout_ms, ConfigLock.timeout_ms())
         ) do
      {:ok, result} -> result
      {:error, :timeout} -> {:error, :busy, "config.toml is locked by another helmsman process"}
      {:error, _} -> {:error, :config_error, "could not lock config.toml"}
    end
  end

  defp do_register(push, opts) do
    trace = Keyword.get(opts, :trace, fn _ -> :ok end)

    with {:ok, text, decoded} <- step(trace, :read_config, fn -> read() end),
         {:ok, root} <- step(trace, :roots, fn -> root(decoded, push.root) end),
         :ok <- step(trace, :path, fn -> path(push.path) end),
         {:ok, candidate} <- step(trace, :walk, fn -> walk(root.real, push.path) end),
         :ok <- step(trace, :dot_git, fn -> dot_git(candidate) end),
         :ok <- step(trace, :check, fn -> repository(candidate, opts) end),
         :ok <- step(trace, :git_dirs, fn -> git_dirs(candidate, root.real, opts) end),
         :ok <- step(trace, :name, fn -> name(push.name) end),
         :ok <- step(trace, :workspaces, fn -> workspaces(push.workspaces) end),
         {:ok, current} <-
           step(trace, :configured, fn -> configured(decoded, push.name, candidate) end) do
      entry = %{
        "added_at" => now(opts),
        "added_from" => "web",
        "name" => push.name,
        "path" => candidate,
        "request_id" => push.request_id,
        "workspaces" => push.workspaces
      }

      step(trace, :write, fn -> write(text, decoded, current ++ [entry], opts) end)
    end
  end

  defp do_remove(push, opts) do
    trace = Keyword.get(opts, :trace, fn _ -> :ok end)

    with {:ok, text, decoded} <- step(trace, :read_config, fn -> read() end),
         :ok <- step(trace, :roots, fn -> enabled(decoded) end),
         {:ok, rest} <- step(trace, :configured, fn -> without(decoded, push.name) end) do
      step(trace, :write, fn -> write(text, decoded, rest, opts) end)
    end
  end

  defp step(trace, name, fun) do
    trace.(name)
    fun.()
  end

  # An unreadable configuration has no roots: web registration is off.
  defp read do
    case ConfigFile.read() do
      {:ok, text, decoded} -> {:ok, text, decoded}
      {:error, _} -> {:error, :disabled, nil}
    end
  end

  defp root(decoded, label) do
    case Roots.valid(decoded) do
      [] ->
        {:error, :disabled, nil}

      roots ->
        case Enum.find(roots, &(&1.label == label)) do
          nil -> {:error, :root_not_allowed, nil}
          root -> {:ok, root}
        end
    end
  end

  defp enabled(decoded) do
    if Roots.valid(decoded) == [], do: {:error, :disabled, nil}, else: :ok
  end

  defp path(path) do
    if RepoField.path?(path) and (path == "." or length(String.split(path, "/")) <= @max_depth),
      do: :ok,
      else: {:error, :invalid_path, nil}
  end

  # Component by component below the root: no symbolic link, every one a directory.
  defp walk(root, "."), do: {:ok, root}

  defp walk(root, path) do
    Enum.reduce_while(String.split(path, "/"), {:ok, root}, fn segment, {:ok, dir} ->
      next = Path.join(dir, segment)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :outside_root, nil}}
        {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, next}}
        _ -> {:halt, {:error, :missing, nil}}
      end
    end)
  end

  defp dot_git(candidate) do
    case File.lstat(Path.join(candidate, ".git")) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :outside_root, nil}
      _ -> :ok
    end
  end

  defp repository(candidate, opts) do
    cond do
      LocalRepos.inside_home?(candidate) or inside?(candidate, Roots.home_real()) ->
        {:error, :inside_daemon_home, nil}

      problem = LocalRepos.path_problem(candidate, opts) ->
        {:error, :not_a_repository, problem}

      true ->
        :ok
    end
  end

  # The git directory and the common git directory (gitfiles of linked
  # worktrees and submodules) must be inside the root as well.
  defp git_dirs(candidate, root, opts) do
    case LocalRepos.git(["rev-parse", "--absolute-git-dir", "--git-common-dir"], candidate, opts) do
      {:ok, output} ->
        dirs = output |> String.split("\n", trim: true) |> Enum.map(&absolute(&1, candidate))

        if length(dirs) == 2 and Enum.all?(dirs, &inside_real?(&1, root)),
          do: :ok,
          else: {:error, :outside_root, nil}

      {:error, _} ->
        {:error, :not_a_repository, "not a git repository"}
    end
  end

  defp absolute(path, base),
    do: if(Path.type(path) == :absolute, do: path, else: Path.join(base, path))

  defp inside_real?(path, root) do
    case Roots.real_path(path) do
      {:ok, real} -> inside?(real, root)
      _ -> false
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp name(name) do
    if LocalRepos.valid_name?(name), do: :ok, else: {:error, :invalid_name, nil}
  end

  defp workspaces(ids) do
    served = Enum.map(LocalRepos.served() || [], & &1.id)

    if ids != [] and Enum.uniq(ids) == ids and served != [] and Enum.all?(ids, &(&1 in served)),
      do: :ok,
      else: {:error, :invalid_workspaces, nil}
  end

  defp configured(decoded, name, candidate) do
    case ConfigFile.local_repositories(decoded) do
      {:ok, current} ->
        cond do
          Enum.any?(current, &(&1["name"] == name)) ->
            {:error, :name_taken, nil}

          entry = Enum.find(current, &same_path?(&1["path"], candidate)) ->
            {:error, :already_registered, "already registered as #{entry["name"]}"}

          true ->
            {:ok, current}
        end

      {:error, reason} ->
        {:error, :config_error, reason}
    end
  end

  defp same_path?(path, candidate) when is_binary(path),
    do: Roots.real_path(path) == {:ok, candidate}

  defp same_path?(_, _), do: false

  defp without(decoded, name) do
    case ConfigFile.local_repositories(decoded) do
      {:ok, current} ->
        case Enum.reject(current, &(&1["name"] == name)) do
          ^current -> {:error, :not_configured, nil}
          rest -> {:ok, rest}
        end

      {:error, reason} ->
        {:error, :config_error, reason}
    end
  end

  defp write(text, decoded, list, opts) do
    case ConfigFile.write_local_repositories(text, decoded, list, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, :config_error, reason}
    end
  end

  defp now(opts) do
    Keyword.get(opts, :now, &DateTime.utc_now/0).()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp log(:ok, push, _action, verb) do
    Logger.info("Local repository #{push.name} #{verb} from the web (request #{push.request_id})")
    :ok
  end

  defp log({:error, code, _} = error, push, action, _verb) do
    Logger.info(
      "Web request #{push.request_id} to #{action} local repository #{push.name} refused: #{code}"
    )

    error
  end
end
