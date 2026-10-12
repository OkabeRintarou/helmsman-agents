defmodule HelmsmanDaemon.RepoCache do
  @moduledoc "Caller-owned local locks for shared repositories and task worktrees."

  def with_repo_lock(key, fun), do: with_lock({:hm_repo, key}, fun)
  def with_worktree_lock(path, fun), do: with_lock({:hm_worktree, path}, fun)

  @doc "Locks held by this caller, for command cleanup barriers."
  def command_locks, do: Process.get({__MODULE__, :locks}, [])

  @doc "Join caller locks before launching a command; release only after cleanup."
  def with_command_locks(locks, fun), do: pin_locks(locks, fun)

  defp pin_locks([], fun), do: fun.()

  defp pin_locks([lock | rest], fun) do
    if :global.set_lock(lock, [node()], 0) do
      try do
        pin_locks(rest, fun)
      after
        :global.del_lock(lock, [node()])
      end
    else
      {:error, {:owner_down, "caller lock was already handed off"}}
    end
  end

  defp with_lock(resource, fun) do
    lock = {resource, self()}
    true = :global.set_lock(lock, [node()], :infinity)

    previous = command_locks()
    Process.put({__MODULE__, :locks}, Enum.uniq([lock | previous]))

    try do
      fun.()
    after
      Process.put({__MODULE__, :locks}, previous)
      :global.del_lock(lock, [node()])
    end
  end
end
