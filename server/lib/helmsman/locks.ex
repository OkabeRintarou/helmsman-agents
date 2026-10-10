defmodule Helmsman.Locks do
  @moduledoc """
  Transaction-level advisory locks (designs/01 §4).

  Every lock uses a single `bigint` key `type <<< 48 ||| id`, so the key
  spaces of different lock types never overlap. `id` must be below 2^48.

  | type | lock                                      |
  |------|-------------------------------------------|
  | 0    | global constants (`1` = registration lock) |
  | 1    | workspace maintenance lock                |
  | 2    | workspace graph lock                      |
  | 3    | task lock                                 |
  | 4    | daemon lock                               |

  All functions take `pg_*_xact_lock`s and must run inside a transaction;
  the locks are released when it ends.
  """

  import Bitwise

  alias Helmsman.Repo

  @id_bits 48
  @max_id 1 <<< @id_bits

  @types %{global: 0, maint: 1, graph: 2, task: 3, daemon: 4}

  @type lock_type :: :global | :maint | :graph | :task | :daemon

  @doc """
  Returns the advisory lock key for `type` and `id`.

  Raises `ArgumentError` if `id` is negative or not below 2^48.
  """
  @spec key(lock_type(), non_neg_integer()) :: non_neg_integer()
  def key(type, id) when is_map_key(@types, type) and is_integer(id) do
    if id < 0 or id >= @max_id do
      raise ArgumentError, "advisory lock id must be in 0..2^48-1, got: #{id}"
    end

    @types[type] <<< @id_bits ||| id
  end

  @doc "Takes the global registration lock (exclusive)."
  @spec registration!() :: :ok
  def registration!, do: lock!("pg_advisory_xact_lock", key(:global, 1))

  @doc "Takes the workspace maintenance lock in shared mode (all writes)."
  @spec maint_shared!(pos_integer()) :: :ok
  def maint_shared!(workspace_id),
    do: lock!("pg_advisory_xact_lock_shared", key(:maint, workspace_id))

  @doc "Takes the workspace maintenance lock in exclusive mode (import)."
  @spec maint_exclusive!(pos_integer()) :: :ok
  def maint_exclusive!(workspace_id),
    do: lock!("pg_advisory_xact_lock", key(:maint, workspace_id))

  @doc "Tries the workspace maintenance lock in shared mode without waiting."
  @spec try_maint_shared(pos_integer()) :: boolean()
  def try_maint_shared(workspace_id),
    do: try_lock("pg_try_advisory_xact_lock_shared", key(:maint, workspace_id))

  @doc "Takes the workspace graph lock (exclusive)."
  @spec graph!(pos_integer()) :: :ok
  def graph!(workspace_id), do: lock!("pg_advisory_xact_lock", key(:graph, workspace_id))

  @doc "Tries the task lock without waiting."
  @spec try_task(pos_integer()) :: boolean()
  def try_task(task_id), do: try_lock("pg_try_advisory_xact_lock", key(:task, task_id))

  @doc "Tries the daemon lock without waiting."
  @spec try_daemon(pos_integer()) :: boolean()
  def try_daemon(daemon_id), do: try_lock("pg_try_advisory_xact_lock", key(:daemon, daemon_id))

  defp lock!(function, key) do
    ensure_transaction!()
    Repo.query!("SELECT #{function}($1)", [key])
    :ok
  end

  defp try_lock(function, key) do
    ensure_transaction!()
    %{rows: [[acquired?]]} = Repo.query!("SELECT #{function}($1)", [key])
    acquired?
  end

  # Outside a transaction an xact lock would be released right after the
  # statement, which silently protects nothing.
  defp ensure_transaction! do
    unless Repo.in_transaction?() do
      raise "transaction-level advisory locks must be taken inside a transaction"
    end
  end
end
