defmodule HelmsmanDaemon.CredentialsLock do
  @moduledoc """
  Serializes credential recovery, writes and deletion across CLI processes.

  A bundled POSIX helper holds an advisory lock on the stable 0600
  `credentials.lock` inode. Its stdin belongs to the caller's Erlang port:
  closing the port, process death or VM death releases the kernel lock.
  The file is never removed and contains no credentials or owner metadata.
  """
  alias HelmsmanDaemon.{Env, Paths}

  def with_lock(fun) do
    key = {__MODULE__, Paths.home()}

    if Process.get(key) do
      fun.()
    else
      acquire(key, fun)
    end
  end

  defp acquire(key, fun) do
    Paths.private_dir!(Paths.home())
    executable = Application.app_dir(:helmsman_daemon, "priv/credentials_lock")

    case open(executable) do
      {:ok, port} -> hold(port, key, fun)
      error -> error
    end
  end

  defp open(executable) do
    {:ok, Env.port(executable, [Path.join(Paths.home(), "credentials.lock")])}
  rescue
    ErlangError -> {:error, :credentials_lock}
  end

  defp hold(port, key, fun) do
    receive do
      {^port, {:data, "locked\n"}} ->
        Process.put(key, true)
        fun.()

      {^port, {:exit_status, _}} ->
        {:error, :credentials_lock}
    after
      30_000 -> {:error, :credentials_lock_timeout}
    end
  after
    Process.delete(key)
    if Port.info(port), do: Port.close(port)
  end
end
