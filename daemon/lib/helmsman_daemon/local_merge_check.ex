defmodule HelmsmanDaemon.LocalMergeCheck do
  @moduledoc """
  Checks whether delivered local task branches are merged into their base branch
  (decision 13) and reports `repo_status`.

  The watch list comes from the latest `join` / `sync` reply. Checks run after a
  reply with a non-empty watch, every 10 minutes, and after a local run's
  finalization; one check runs at a time, outside the Channel process.
  """
  use GenServer
  require Logger
  alias HelmsmanDaemon.{Git, LocalRepos, Paths, RepoCache}
  alias HelmsmanProtocol.Report

  @interval 600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Replaces the watch lists with a reply's `local_repositories`."
  def update(repositories), do: GenServer.cast(__MODULE__, {:update, repositories})

  @doc "Checks one repository with its latest watch list (after a local run)."
  def after_run(workspace_id, name),
    do: GenServer.cast(__MODULE__, {:check, [{workspace_id, name}]})

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :merge_check_interval_ms, @interval)
    Process.send_after(self(), :tick, interval)

    {:ok,
     %{
       watch: %{},
       queue: [],
       task: nil,
       interval: interval,
       send: Keyword.get(opts, :repo_status_sender, &HelmsmanDaemon.Connection.repo_status/1),
       git_opts: Keyword.take(opts, [:base_env, :executable])
     }}
  end

  @impl true
  def handle_cast({:update, repositories}, state) do
    watch = Map.new(repositories, fn repo -> {{repo.workspace_id, repo.name}, repo.watch} end)

    keys = for {key, [_ | _]} <- watch, do: key
    {:noreply, %{state | watch: watch} |> enqueue(keys) |> start_next()}
  end

  def handle_cast({:check, keys}, state),
    do: {:noreply, state |> enqueue(keys) |> start_next()}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    keys = for {key, [_ | _]} <- state.watch, do: key
    {:noreply, state |> enqueue(keys) |> start_next()}
  end

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, start_next(%{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("Local merge check failed: #{inspect(reason)}")
    {:noreply, start_next(%{state | task: nil})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp enqueue(state, keys), do: %{state | queue: Enum.uniq(state.queue ++ keys)}

  defp start_next(%{task: nil, queue: [key | rest]} = state) do
    case Map.get(state.watch, key, []) do
      [] ->
        start_next(%{state | queue: rest})

      watch ->
        {workspace_id, name} = key
        sender = state.send
        git_opts = state.git_opts
        task = Task.async(fn -> run_check(workspace_id, name, watch, git_opts, sender) end)
        %{state | task: task, queue: rest}
    end
  end

  defp start_next(state), do: state

  defp run_check(workspace_id, name, watch, git_opts, sender) do
    case check(workspace_id, name, watch, git_opts) do
      {:ok, report} -> sender.(report)
      :skip -> :ok
    end
  end

  @doc "Fetches the user's repository into the cache and classifies every watched branch."
  def check(workspace_id, name, watch, opts \\ []) do
    if LocalRepos.valid_name?(name) do
      cache = LocalRepos.cache_path(name)

      RepoCache.with_repo_lock(cache, fn ->
        locked_check(cache, workspace_id, name, watch, opts)
      end)
    else
      :skip
    end
  end

  # Sharing is read once the lock is held (it may be revoked while waiting) and
  # again right before the fetch, the only access to the user's repository.
  defp locked_check(cache, workspace_id, name, watch, opts) do
    with {:ok, %{path: path}} <- LocalRepos.resolve(name, workspace_id, opts),
         {:ok, fetched?} <- fetch(cache, path, workspace_id, name, opts) do
      git = Git.context(Paths.home(), nil, opts)

      results =
        Enum.map(watch, fn item ->
          %Report.RepoStatus.Result{
            branch: item.branch,
            head_sha: item.head_sha,
            merged: if(fetched?, do: merged(cache, item, git), else: :unknown)
          }
        end)

      {:ok,
       %Report.RepoStatus{
         workspace_id: workspace_id,
         name: name,
         results: Enum.take(results, 500)
       }}
    else
      {:error, message} ->
        Logger.info("Skipping merge check: #{message}")
        :skip
    end
  end

  defp fetch(cache, path, workspace_id, name, opts) do
    git = Git.context(Paths.home(), nil, opts)

    if File.dir?(cache) and origin(cache, path, git) do
      case LocalRepos.resolve(name, workspace_id, opts) do
        {:ok, %{path: ^path}} ->
          args = ["fetch"] ++ Git.local_transport(git, :upload) ++ ["--prune", "origin"]
          {:ok, match?({:ok, _}, Git.run(args, cache, git))}

        {:ok, _moved} ->
          {:error, "local repository #{name} now points to another path on this machine"}

        error ->
          error
      end
    else
      {:ok, false}
    end
  end

  defp origin(cache, path, git) do
    case Git.run(["remote", "get-url", "origin"], cache, git) do
      {:ok, url} ->
        String.trim(url) == path or
          match?({:ok, _}, Git.run(["remote", "set-url", "origin", path], cache, git))

      _ ->
        false
    end
  end

  defp merged(cache, item, git) do
    base = "refs/remotes/origin/" <> item.base_branch

    with true <- Regex.match?(~r/\A[0-9a-f]{40,64}\z/, item.head_sha),
         true <- ok?(Git.run(["cat-file", "-e", item.head_sha <> "^{commit}"], cache, git)),
         true <- ok?(Git.run(["rev-parse", "--verify", "--quiet", base], cache, git)) do
      case Git.run(["merge-base", "--is-ancestor", item.head_sha, base], cache, git) do
        {:ok, _} -> :yes
        {:error, {{:exit_status, 256}, _}} -> :no
        _ -> :unknown
      end
    else
      _ -> :unknown
    end
  end

  defp ok?({:ok, _}), do: true
  defp ok?(_), do: false
end
