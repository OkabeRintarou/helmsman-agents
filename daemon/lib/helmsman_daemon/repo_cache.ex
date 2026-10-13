defmodule HelmsmanDaemon.RepoCache do
  @moduledoc "Caller-owned local locks for shared repositories and task worktrees."

  def with_repo_lock(key, fun), do: with_lock({:hm_repo, key}, fun)

  def with_repo_lock_until(key, deadline, fun) do
    lock = {{:hm_repo, key}, self()}

    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      :global.set_lock(lock, [node()], 0) ->
        previous = command_locks()
        Process.put({__MODULE__, :locks}, Enum.uniq([lock | previous]))

        try do
          fun.()
        after
          Process.put({__MODULE__, :locks}, previous)
          :global.del_lock(lock, [node()])
        end

      true ->
        Process.sleep(10)
        with_repo_lock_until(key, deadline, fun)
    end
  end

  def with_worktree_lock(path, fun), do: with_lock({:hm_worktree, path}, fun)

  @doc "Take both cleanup locks immediately, or skip without waiting."
  def try_cleanup_locks(path, cache, fun) do
    locks = [{{:hm_worktree, path}, self()}, {{:hm_repo, cache}, self()}]
    try_locks(locks, fun)
  end

  defp try_locks([], fun), do: fun.()

  defp try_locks([lock | rest], fun) do
    if :global.set_lock(lock, [node()], 0) do
      previous = command_locks()
      Process.put({__MODULE__, :locks}, [lock | previous])

      try do
        try_locks(rest, fun)
      after
        Process.put({__MODULE__, :locks}, previous)
        :global.del_lock(lock, [node()])
      end
    else
      {:error, :busy}
    end
  end

  def acquire_worktree(path), do: acquire({:hm_worktree, path})

  def release(lock) do
    Process.put({__MODULE__, :locks}, List.delete(command_locks(), lock))
    :global.del_lock(lock, [node()])
  end

  defp acquire(resource) do
    lock = {resource, self()}
    true = :global.set_lock(lock, [node()], :infinity)
    Process.put({__MODULE__, :locks}, Enum.uniq([lock | command_locks()]))
    lock
  end

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
