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
  | 5    | pull request reconciliation (session lock) |
  | 6    | creating an autopilot in a workspace      |

  All functions but the session ones take `pg_*_xact_lock`s and must run
  inside a transaction; the locks are released when it ends. The
  reconciliation lock is a session lock (`try_session/2`,
  `unlock_session/2`) held across the HTTP calls of one reconciliation on
  a checked-out connection (`add-pr-reconcile-merge` decision 3); it is
  released explicitly or when the connection closes.
  """

  import Bitwise

  alias Helmsman.Repo

  @id_bits 48
  @max_id 1 <<< @id_bits

  @types %{global: 0, maint: 1, graph: 2, task: 3, daemon: 4, reconcile: 5, autopilots: 6}

  @type lock_type :: :global | :maint | :graph | :task | :daemon | :reconcile | :autopilots

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

  @doc """
  Takes the lock that serializes creating autopilots in a workspace
  (exclusive; the per-workspace limit, `add-autopilots` decision 1). Taken
  after the membership row, where the autopilot rows go.
  """
  @spec autopilots!(pos_integer()) :: :ok
  def autopilots!(workspace_id),
    do: lock!("pg_advisory_xact_lock", key(:autopilots, workspace_id))

  @doc "Takes the workspace graph lock (exclusive)."
  @spec graph!(pos_integer()) :: :ok
  def graph!(workspace_id), do: lock!("pg_advisory_xact_lock", key(:graph, workspace_id))

  @doc "Tries the workspace graph lock without waiting (claiming)."
  @spec try_graph(pos_integer()) :: boolean()
  def try_graph(workspace_id),
    do: try_lock("pg_try_advisory_xact_lock", key(:graph, workspace_id))

  @doc "Tries the task lock without waiting."
  @spec try_task(pos_integer()) :: boolean()
  def try_task(task_id), do: try_lock("pg_try_advisory_xact_lock", key(:task, task_id))

  @doc "Tries the daemon lock without waiting."
  @spec try_daemon(pos_integer()) :: boolean()
  def try_daemon(daemon_id), do: try_lock("pg_try_advisory_xact_lock", key(:daemon, daemon_id))

  @doc """
  Tries the session-level lock `type`/`id` without waiting, outside any
  transaction. The caller must hold the connection (`Repo.checkout/2`)
  until `unlock_session/2`.
  """
  @spec try_session(lock_type(), non_neg_integer()) :: boolean()
  def try_session(type, id) do
    %{rows: [[acquired?]]} = Repo.query!("SELECT pg_try_advisory_lock($1)", [key(type, id)])
    acquired?
  end

  @doc "Releases a session-level lock taken with `try_session/2`."
  @spec unlock_session(lock_type(), non_neg_integer()) :: boolean()
  def unlock_session(type, id) do
    %{rows: [[released?]]} = Repo.query!("SELECT pg_advisory_unlock($1)", [key(type, id)])
    released?
  end

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
