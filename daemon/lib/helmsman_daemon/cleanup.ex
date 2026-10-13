defmodule HelmsmanDaemon.Cleanup do
  @moduledoc "Daily cleanup of validated daemon caches, without contacting GitHub."
  use GenServer
  require Logger
  alias HelmsmanDaemon.{Connection, Git, GitLedger, Paths, RepoCache}
  alias HelmsmanProtocol.{Reply, Report}
  @interval 24 * 60 * 60 * 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def joined(version), do: cast({:joined, version})
  def disconnected, do: cast(:disconnected)

  defp cast(message) do
    if pid = Process.whereis(__MODULE__), do: GenServer.cast(pid, message)
    :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{opts: opts, version: nil, started?: false, task: nil}}
  end

  @impl true
  def handle_cast({:joined, version}, state) do
    state = %{state | version: version}

    if not state.started? and version >= HelmsmanProtocol.cleanup_version() do
      schedule(state)
      {:noreply, launch(%{state | started?: true})}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:disconnected, state), do: {:noreply, %{state | version: nil}}

  @impl true
  def handle_info(:cleanup_tick, state) do
    schedule(state)
    {:noreply, launch(state)}
  end

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.info("Cleanup round stopped: #{inspect(reason)}")
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{task: %Task{} = task}), do: Task.shutdown(task, 5_000)
  def terminate(_, _), do: :ok

  defp schedule(state) do
    scheduler = Keyword.get(state.opts, :cleanup_schedule, &Process.send_after/3)
    scheduler.(self(), :cleanup_tick, @interval)
  end

  defp launch(%{task: nil, version: version} = state) when is_integer(version) do
    if version >= HelmsmanProtocol.cleanup_version() do
      check = Keyword.get(state.opts, :cleanup_check, &Connection.cleanup_check/1)
      task = Task.async(fn -> run(check, state.opts) end)
      %{state | task: task}
    else
      state
    end
  end

  defp launch(state), do: state

  @doc "Run one local round; the supplied check function returns a typed Channel reply."
  def run(check, opts \\ []) do
    home = Paths.home()
    git = Git.context(home, "cleanup-no-token", Keyword.get(opts, :cleanup_git_opts, []))

    with :ok <- plain_path(home),
         {:ok, candidates} <- candidates(home, git) do
      candidates
      |> Enum.chunk_every(500)
      |> Enum.each(&check_batch(&1, check, git))

      :ok
    else
      error -> log(home, error)
    end
  end

  defp candidates(home, git) do
    work = Path.join(home, "work")

    with :ok <- directory(work), {:ok, workspaces} <- File.ls(work) do
      entries =
        for wid <- workspaces,
            Regex.match?(~r/\A[0-9]+\z/, wid),
            String.to_integer(wid) > 0,
            {:ok, names} <- [list_directory(Path.join(work, wid))],
            name <- names,
            do: %{
              workspace_id: String.to_integer(wid),
              ident: name,
              wid: wid,
              path: Path.join([work, wid, name]),
              home: home
            }

      {:ok, Enum.flat_map(entries, &validated(&1, git))}
    else
      {:error, :enoent} -> {:ok, []}
      error -> error
    end
  end

  defp list_directory(path) do
    case directory(path) do
      :ok ->
        File.ls(path)

      error ->
        log(path, error)
        error
    end
  end

  defp validated(entry, git) do
    case layout(entry, git) do
      {:ok, candidate} ->
        [candidate]

      error ->
        log(entry.path, error)
        []
    end
  end

  defp layout(entry, git) do
    dotgit = Path.join(entry.path, ".git")

    with :ok <- component(entry.ident),
         :ok <- plain_path(entry.path),
         :ok <- directory(entry.path),
         :ok <- regular(dotgit),
         {:ok, contents} <- File.read(dotgit),
         "gitdir: " <> gitdir <- String.trim(contents),
         {:ok, metadata} <- canonical(Path.expand(gitdir, entry.path)),
         cache <- metadata |> Path.dirname() |> Path.dirname(),
         :ok <- cache_layout(cache, entry.home),
         true <- Path.dirname(metadata) == Path.join(cache, "worktrees"),
         :ok <- directory(metadata),
         {:ok, "true"} <- command(git, cache, ["rev-parse", "--is-bare-repository"]),
         :ok <- regular(Path.join(metadata, "gitdir")),
         {:ok, reverse} <- File.read(Path.join(metadata, "gitdir")),
         {:ok, ^dotgit} <- canonical(Path.expand(String.trim(reverse), metadata)),
         {:ok, common} <-
           command(git, entry.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, ^cache} <- canonical(common),
         branch <- "hm/#{entry.wid}/#{String.downcase(entry.ident)}",
         {:ok, actual} <- command(git, entry.path, ["symbolic-ref", "-q", "HEAD"]),
         true <- actual == "refs/heads/" <> branch do
      {:ok, Map.merge(entry, %{cache: cache, metadata: metadata, branch: branch})}
    else
      _ -> {:error, :not_helmsman_cache_or_task_branch}
    end
  end

  defp cache_layout(cache, home) do
    case Path.split(Path.relative_to(cache, Path.join(home, "repos"))) do
      [host, name] when host not in [".", ".."] ->
        if (host == "local" and String.ends_with?(name, ".git") and name != ".git") or
             (host != "local" and Regex.match?(~r/\A[0-9]+\.git\z/, name)) do
          plain_path(cache)
        else
          {:error, :cache_layout}
        end

      _ ->
        {:error, :cache_layout}
    end
  end

  defp check_batch(batch, check, git) do
    items = Enum.map(batch, &Map.take(&1, [:workspace_id, :ident]))
    {:ok, report} = Report.CleanupCheck.new(items: items)

    case check.(report.items) do
      {:ok, %Reply.CleanupCheck{} = reply} ->
        case Reply.CleanupCheck.new(Map.from_struct(reply)) do
          {:ok, validated} -> Enum.each(batch, &apply_result(&1, validated.results, git))
          error -> log("round", error)
        end

      error ->
        log("round", error)
    end
  end

  defp apply_result(candidate, results, git) do
    matches =
      Enum.filter(
        results,
        &(&1.workspace_id == candidate.workspace_id and &1.ident == candidate.ident)
      )

    case matches do
      [%{deletable: true} = result] ->
        outcome =
          RepoCache.try_cleanup_locks(candidate.path, candidate.cache, fn ->
            cleanup_locked(candidate, result, git)
          end)

        if outcome != :ok, do: log(candidate.path, outcome)

      _ ->
        log(candidate.path, {:error, :server_not_deletable})
    end
  end

  defp cleanup_locked(candidate, result, git) do
    with :ok <- plain_path(candidate.home),
         {:ok, fresh} <- layout(candidate, git),
         true <- fresh.cache == candidate.cache and fresh.metadata == candidate.metadata,
         :ok <- safe(fresh, result, git) do
      remove(fresh, git)
    else
      false -> {:error, :layout_changed}
      error -> error
    end
  end

  defp safe(candidate, result, git) do
    with :ok <- ledger_empty(candidate),
         {:ok, ""} <-
           command(git, candidate.path, [
             "status",
             "--porcelain=v1",
             "--untracked-files=all",
             "--ignored=matching"
           ]),
         false <- unfinished?(candidate.metadata),
         true <- delivered?(candidate, result, git) do
      :ok
    else
      {:ok, _} -> {:error, :uncommitted_or_untracked_changes}
      true -> {:error, :unfinished_git_operation}
      false -> {:error, :unpushed_commits}
      error -> error
    end
  end

  defp ledger_path(candidate) do
    GitLedger.path(%{workspace: %{id: candidate.workspace_id}, task: %{ident: candidate.ident}})
  end

  defp ledger_empty(candidate) do
    path = ledger_path(candidate)

    result = with :ok <- plain_existing_parents(path), do: read_empty_ledger(path)

    case result do
      :ok -> :ok
      _ -> {:error, :pending_or_unsafe_ledger}
    end
  end

  defp read_empty_ledger(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :regular}} ->
        with {:ok, contents} <- File.read(path),
             {:ok, %{"inherit" => [], "outbox" => []}} <- Jason.decode(contents),
             do: :ok

      _ ->
        {:error, :unsafe_ledger}
    end
  end

  defp unfinished?(metadata) do
    Enum.any?(
      ~w(MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer),
      fn name -> File.lstat(Path.join(metadata, name)) != {:error, :enoent} end
    )
  end

  defp delivered?(candidate, result, git) do
    refs =
      result.pushed_heads ++
        if(is_binary(result.base_branch),
          do: ["refs/remotes/origin/" <> result.base_branch],
          else: []
        )

    Enum.any?(refs, fn ref ->
      match?({:ok, _}, command(git, candidate.path, ["merge-base", "--is-ancestor", "HEAD", ref]))
    end)
  end

  defp remove(candidate, git) do
    with {:ok, _} <- command(git, candidate.cache, ["worktree", "remove", candidate.path]),
         {:ok, _} <- command(git, candidate.cache, ["branch", "-D", candidate.branch]),
         {:ok, _} <- command(git, candidate.cache, ["worktree", "prune"]) do
      case File.rm(ledger_path(candidate)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    end
  end

  defp command(git, cwd, args) do
    case Git.run(args, cwd, git) do
      {:ok, output} -> {:ok, String.trim(output)}
      error -> error
    end
  end

  defp component(value) do
    Paths.component!(value)
    :ok
  rescue
    ArgumentError -> {:error, :component}
  end

  defp directory(path), do: file_type(path, :directory)
  defp regular(path), do: file_type(path, :regular)

  defp file_type(path, type) do
    case File.lstat(path) do
      {:ok, %{type: ^type}} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :unsafe_path}
    end
  end

  # Every existing ancestor is checked, including ancestors above HELMSMAN_HOME.
  defp plain_path("/"), do: :ok

  defp plain_path(path) do
    with :ok <- directory(path), do: plain_path(Path.dirname(path))
  end

  defp plain_existing_parents(path) do
    parent = Path.dirname(path)

    case File.lstat(parent) do
      {:error, :enoent} -> plain_existing_parents(parent)
      {:ok, %{type: :directory}} -> plain_path(parent)
      _ -> {:error, :unsafe_path}
    end
  end

  defp canonical(path, remaining \\ 40)
  defp canonical(_, 0), do: {:error, :symlink_loop}

  defp canonical(path, remaining) do
    path = Path.expand(path)
    parts = Path.split(path)
    resolve_parts(parts, "/", remaining)
  end

  defp resolve_parts([], path, _), do: {:ok, path}
  defp resolve_parts(["/" | rest], path, remaining), do: resolve_parts(rest, path, remaining)

  defp resolve_parts([part | rest], parent, remaining) do
    path = Path.join(parent, part)

    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        with {:ok, target} <- File.read_link(path) do
          canonical(Path.join([Path.expand(target, parent) | rest]), remaining - 1)
        end

      {:ok, _} ->
        resolve_parts(rest, path, remaining)

      error ->
        error
    end
  end

  defp log(path, reason), do: Logger.info("Cleanup preserved #{path}: #{inspect(reason)}")
end
