defmodule HelmsmanDaemon.GitWorkspace do
  @moduledoc "Repository-cache and task-worktree preparation, without starting an Agent."
  alias HelmsmanDaemon.{Git, Paths, RepoCache}

  @derive {Inspect, only: [:path, :cache, :remote_base, :remote_branch?, :events]}
  defstruct [:path, :cache, :git, :remote_base, :remote_branch?, events: []]

  def prepare(spec, run_dir, opts \\ []) do
    timeout = Keyword.get(opts, :prepare_timeout_ms, 480_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    identity = Git.identity(spec.agent.name, Keyword.get(opts, :server_url, "http://localhost"))
    git_opts = Keyword.merge(opts, deadline: deadline, identity: identity)
    git = Git.context(run_dir, spec.repo.git_token, git_opts)
    path = worktree_path(spec)
    cache = cache_path(spec.repo.clone_url, spec.repo.github_repository_id, opts)
    state = %__MODULE__{path: path, cache: cache, git: git}
    Git.write_askpass(git)
    checked!(Git.check_version(git))

    prepare = fn -> RepoCache.with_repo_lock(cache, fn -> prepare_locked(state, spec) end) end

    if Keyword.get(opts, :worktree_locked?, false),
      do: prepare.(),
      else: RepoCache.with_worktree_lock(path, prepare)
  rescue
    error in [ArgumentError, File.Error] ->
      {:error, {:workspace_prepare, Git.redact(Exception.message(error))}}
  catch
    {:git_prepare, :timeout, _output} ->
      {:error, {:workspace_prepare, "repository preparation exceeded 8 minutes"}}

    {:git_prepare, _reason, output} ->
      {:error, {:workspace_prepare, output}}
  end

  def worktree_path(spec) do
    Path.join([
      Paths.home(),
      "work",
      Paths.component!(to_string(spec.workspace.id)),
      Paths.component!(spec.task.ident)
    ])
  end

  def cache_path(url, id, opts \\ []) when is_integer(id) and id > 0 do
    host = repository_host(URI.parse(url), opts)
    Path.join([Paths.home(), "repos", Paths.component!(host), "#{id}.git"])
  end

  defp repository_host(%URI{scheme: "https", host: host, userinfo: nil}, _opts)
       when is_binary(host),
       do: host

  defp repository_host(%URI{scheme: "file", host: host, path: path}, opts)
       when host in [nil, "", "localhost"] and is_binary(path) do
    unless Keyword.get(opts, :allow_file_urls, false),
      do: raise(ArgumentError, "file repositories are only allowed in tests")

    "file"
  end

  defp repository_host(_, _),
    do: raise(ArgumentError, "repository URL must be HTTPS without credentials")

  defp prepare_locked(state, spec) do
    state = initialize(state, spec.repo.clone_url)
    state = fetch(state, spec.run_id)
    state = ensure_worktree(state, spec.repo)
    state = remove_index_lock(state)
    remote = "refs/remotes/origin/" <> spec.repo.branch
    remote? = exists?(state, remote)
    base = if remote?, do: remote, else: "refs/remotes/origin/" <> spec.repo.base_branch

    state = %{
      state
      | remote_base: String.trim(run!(state, ["rev-parse", "--verify", base])),
        remote_branch?: remote?
    }

    state = Keyword.get(state.git.opts, :after_fetch, fn current -> current end).(state)

    state =
      if dirty?(state) do
        warn(
          state,
          "worktree has uncommitted changes or an unfinished merge from an earlier run; not updated from the remote"
        )
      else
        state
        |> sync_remote(remote, remote?)
        |> merge_rescues(spec.repo.rescue_branches)
        |> merge_base(spec)
      end

    {:ok, state}
  end

  defp initialize(state, url) do
    if File.exists?(state.cache) do
      unless String.trim(run!(state, ["rev-parse", "--is-bare-repository"], state.cache)) ==
               "true",
             do: fail!("repository cache needs manual attention")
    else
      Paths.private_dir!(state.cache)
      run!(state, ["init", "--bare", state.cache], state.git.run_dir)
      run!(state, ["remote", "add", "origin", url], state.cache)
    end

    remove_credentials(state)
    old_url = String.trim(run!(state, ["remote", "get-url", "origin"], state.cache))

    unsafe_url? =
      predicate!(
        state,
        ["config", "--local", "--get-regexp", "^remote\\.origin\\.url$", ".*@.*"],
        state.cache
      )

    state =
      if unsafe_url?,
        do: warn(state, "removed credentials from repository origin URL"),
        else: state

    state =
      if unsafe_url? or old_url != url do
        run!(state, ["remote", "set-url", "origin", url], state.cache)
        event(state, :info, "repository URL changed: #{old_url} → #{Git.redact(url)}")
      else
        state
      end

    run!(
      state,
      [
        "config",
        "--local",
        "--replace-all",
        "remote.origin.fetch",
        "+refs/heads/*:refs/remotes/origin/*"
      ],
      state.cache
    )

    state
  end

  defp remove_credentials(state) do
    case Git.run(
           ["config", "--local", "--name-only", "--get-regexp", "^credential\\."],
           state.cache,
           state.git
         ) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.uniq()
        |> Enum.each(fn key ->
          run!(state, ["config", "--local", "--unset-all", key], state.cache)
        end)

      {:error, {{:exit_status, 256}, ""}} ->
        :ok

      {:error, {reason, output}} ->
        throw({:git_prepare, reason, output})
    end
  end

  defp fetch(state, run_id) do
    args = ["fetch", "--prune", "origin"] ++ Keyword.get(state.git.opts, :fetch_args, [])

    case Git.run(args, state.cache, state.git) do
      {:ok, _} -> state
      {:error, {reason, output}} -> retry_fetch(state, run_id, args, reason, output)
    end
  end

  defp retry_fetch(state, run_id, args, reason, output) do
    if Git.classify(output) == :authentication do
      renew = Keyword.get(state.git.opts, :renew_token, fn _ -> {:error, :unavailable} end)

      case renew.(run_id) do
        {:ok, %{token: token}} ->
          state = %{state | git: %{state.git | token: token}}
          run!(state, args, state.cache)
          state

        _ ->
          throw({:git_prepare, reason, output})
      end
    else
      throw({:git_prepare, reason, output})
    end
  end

  defp ensure_worktree(state, repo) do
    if File.exists?(state.path) do
      validate_worktree(state, repo.branch)
    else
      run!(state, ["worktree", "prune"], state.cache)
      start = starting_point(state, repo)
      Paths.private_dir!(Path.dirname(state.path))

      args =
        if start == :local,
          do: ["worktree", "add", state.path, repo.branch],
          else: ["worktree", "add", "--no-track", "-b", repo.branch, state.path, start]

      run!(state, args, state.cache)
    end

    Paths.private_dir!(state.path)
    state
  end

  defp starting_point(state, repo) do
    cond do
      exists?(state, "refs/heads/" <> repo.branch) ->
        :local

      exists?(state, "refs/remotes/origin/" <> repo.branch) ->
        "refs/remotes/origin/" <> repo.branch

      exists?(state, "refs/remotes/origin/" <> repo.base_branch) ->
        "refs/remotes/origin/" <> repo.base_branch

      true ->
        fail!("base branch #{repo.base_branch} not found on the remote")
    end
  end

  defp validate_worktree(state, branch) do
    common = worktree_cache(state)

    with true <- common == state.cache,
         actual <- run!(state, ["symbolic-ref", "--quiet", "HEAD"]),
         true <- String.trim(actual) == "refs/heads/" <> branch do
      :ok
    else
      _ ->
        fail!(
          "#{state.path} belongs to another repository cache (#{common}); move or remove it manually; existing contents were preserved"
        )
    end
  end

  defp worktree_cache(state) do
    if File.regular?(Path.join(state.path, ".git")) do
      case Git.run(["rev-parse", "--git-common-dir"], state.path, state.git) do
        {:ok, common} -> Path.expand(String.trim(common), state.path)
        _ -> "unknown"
      end
    else
      "unknown"
    end
  end

  defp remove_index_lock(state) do
    git_dir = String.trim(run!(state, ["rev-parse", "--absolute-git-dir"]))
    lock = Path.join(git_dir, "index.lock")

    if File.exists?(lock) do
      File.rm!(lock)
      warn(state, "removed stale worktree index.lock")
    else
      state
    end
  end

  def dirty?(state) do
    String.trim(run!(state, ["status", "--porcelain"])) != "" or exists?(state, "MERGE_HEAD")
  end

  defp sync_remote(state, _remote, false), do: state

  defp sync_remote(state, remote, true) do
    cond do
      ancestor?(state, remote, "HEAD") -> state
      ancestor?(state, "HEAD", remote) -> merge(state, remote, ["--ff-only"])
      true -> merge(state, remote, [])
    end
  end

  defp merge_rescues(state, branches) do
    Enum.reduce_while(branches, state, fn branch, current ->
      if exists?(current, "MERGE_HEAD") do
        {:halt,
         warn(
           current,
           "merge conflicts; remaining rescue branches not merged: " <>
             Enum.join(Enum.drop_while(branches, &(&1 != branch)), ", ")
         )}
      else
        {:cont, merge_rescue(current, branch)}
      end
    end)
  end

  defp merge_rescue(state, branch) do
    ref = "refs/remotes/origin/" <> branch

    cond do
      not exists?(state, ref) ->
        warn(state, "rescue branch #{branch} no longer exists on the remote; skipped")

      ancestor?(state, ref, "HEAD") ->
        state

      true ->
        merge(state, ref, ["--no-ff"])
    end
  end

  defp merge_base(state, %{trigger: %{kind: "reopen", reason: "merge_conflict"}, repo: repo}) do
    if exists?(state, "MERGE_HEAD"), do: state, else: merge_rescue(state, repo.base_branch)
  end

  defp merge_base(state, _), do: state

  defp merge(state, ref, flags) do
    case Git.run(["merge", "--no-edit"] ++ flags ++ [ref], state.path, state.git) do
      {:ok, _} ->
        state

      {:error, {reason, output}} ->
        if exists?(state, "MERGE_HEAD"),
          do: warn(state, "merge conflict with #{ref}; conflicts left in worktree"),
          else: throw({:git_prepare, reason, output})
    end
  end

  def ancestor?(state, left, right),
    do: predicate!(state, ["merge-base", "--is-ancestor", left, right])

  defp exists?(state, "MERGE_HEAD"),
    do: predicate!(state, ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], state.path)

  defp exists?(state, ref),
    do: predicate!(state, ["rev-parse", "--verify", "--quiet", ref], state.cache)

  defp predicate!(state, args, cwd \\ nil) do
    case Git.run(args, cwd || state.path, state.git) do
      {:ok, _} -> true
      {:error, {{:exit_status, 256}, _}} -> false
      {:error, {reason, output}} -> throw({:git_prepare, reason, output})
    end
  end

  defp run!(state, args, cwd \\ nil), do: checked!(Git.run(args, cwd || state.path, state.git))
  defp checked!(:ok), do: :ok
  defp checked!({:ok, output}), do: output
  defp checked!({:error, {reason, output}}), do: throw({:git_prepare, reason, output})
  defp fail!(message), do: throw({:git_prepare, :invalid_workspace, message})

  defp warn(state, message), do: event(state, :warning, message)

  defp event(state, level, message),
    do: %{state | events: state.events ++ [{:status, %{level: level, message: message}}]}
end
