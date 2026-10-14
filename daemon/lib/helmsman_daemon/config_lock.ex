defmodule HelmsmanDaemon.ConfigLock do
  @moduledoc """
  Serializes every read-modify-write of `config.toml` (CLI and web requests).

  Holds `HelmsmanDaemon.FileLock` on `config.lock` in the daemon home. Readers
  do not lock: `config.toml` is always replaced atomically.
  """
  alias HelmsmanDaemon.{FileLock, Paths}

  @timeout_ms 10_000

  def path, do: Path.join(Paths.home(), "config.lock")
  def timeout_ms, do: @timeout_ms

  def locked_message, do: "config.toml is locked by another helmsman process; try again"

  @doc """
  Runs `fun` under the lock: `{:ok, result}`, `{:error, :timeout}` after
  `opts[:timeout_ms]` (10 s), or `{:error, :unavailable}` when the lock helper
  cannot run.
  """
  def with_lock(fun, opts \\ []),
    do: FileLock.with_lock(path(), fun, Keyword.get(opts, :timeout_ms, @timeout_ms))
end
