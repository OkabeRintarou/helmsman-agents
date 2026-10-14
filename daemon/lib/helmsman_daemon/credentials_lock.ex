defmodule HelmsmanDaemon.CredentialsLock do
  @moduledoc """
  Serializes credential recovery, writes and deletion across CLI processes.

  Holds `HelmsmanDaemon.FileLock` on `credentials.lock` in the daemon home.
  The file contains no credentials or owner metadata.
  """
  alias HelmsmanDaemon.{FileLock, Paths}

  def with_lock(fun) do
    case FileLock.with_lock(Path.join(Paths.home(), "credentials.lock"), fun, 30_000) do
      {:ok, result} -> result
      {:error, :unavailable} -> {:error, :credentials_lock}
      {:error, :timeout} -> {:error, :credentials_lock_timeout}
    end
  end
end
