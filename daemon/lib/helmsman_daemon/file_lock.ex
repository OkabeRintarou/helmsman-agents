defmodule HelmsmanDaemon.FileLock do
  @moduledoc """
  Advisory lock on a stable 0600 file in the daemon home, across OS processes.

  The bundled POSIX helper `priv/credentials_lock` takes the lock file path as
  its argument and holds the lock until its stdin closes. The stdin belongs to
  the caller's Erlang port: closing the port, process death or VM death
  releases the kernel lock. Lock files are never removed and stay empty.

  Re-entrant within one process (counted in the process dictionary).
  """
  alias HelmsmanDaemon.{Env, Paths}

  @doc """
  Runs `fun` while holding the lock on `path`, waiting at most `timeout_ms`.

  Returns `{:ok, result}` with `fun`'s result, `{:error, :timeout}` when another
  process kept the lock, or `{:error, :unavailable}` when the helper could not run.
  """
  def with_lock(path, fun, timeout_ms) do
    key = {__MODULE__, path}

    case Process.get(key) do
      count when is_integer(count) and count > 0 ->
        Process.put(key, count + 1)

        try do
          {:ok, fun.()}
        after
          Process.put(key, count)
        end

      _ ->
        acquire(path, key, fun, timeout_ms)
    end
  end

  defp acquire(path, key, fun, timeout_ms) do
    Paths.private_dir!(Path.dirname(path))
    executable = Application.app_dir(:helmsman_daemon, "priv/credentials_lock")

    case open(executable, path) do
      {:ok, port} -> hold(port, key, fun, timeout_ms)
      error -> error
    end
  end

  defp open(executable, path) do
    {:ok, Env.port(executable, [path])}
  rescue
    ErlangError -> {:error, :unavailable}
  end

  defp hold(port, key, fun, timeout_ms) do
    receive do
      {^port, {:data, "locked\n"}} ->
        Process.put(key, 1)
        {:ok, fun.()}

      {^port, {:exit_status, _}} ->
        {:error, :unavailable}
    after
      timeout_ms -> {:error, :timeout}
    end
  after
    Process.delete(key)
    if Port.info(port), do: Port.close(port)
  end
end
