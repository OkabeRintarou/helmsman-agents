defmodule Helmsman.Daemons.Locking do
  @moduledoc false
  import Ecto.Query
  alias Helmsman.Daemons.{Daemon, DaemonWorkspace, Runtime}
  alias Helmsman.{Locks, Repo, Tx}
  alias Helmsman.Workspaces.Membership

  def run(id, opts, fun) do
    attempt(id, opts, fun, if(Repo.in_transaction?(), do: 1, else: 3))
  end

  defp attempt(id, opts, fun, attempts) do
    result =
      Tx.run(fn ->
        check_busy!()
        if before = opts[:before], do: before.()
        ids = workspace_ids(id, opts)
        hook(:daemon_pre_read)
        Enum.each(ids, &Locks.maint_shared!/1)

        lock_requested_members(id, opts, ids)

        daemon = Repo.one(from d in Daemon, where: d.id == ^id, lock: "FOR UPDATE")
        hook(:daemon_locked)

        if Enum.any?(workspace_ids(id, opts), &(&1 not in ids)),
          do: Repo.rollback(:daemon_lock_set_changed)

        case daemon do
          nil -> {:error, :not_found}
          daemon -> fun.(daemon, ids)
        end
      end)

    case result do
      {:error, :daemon_lock_set_changed} when attempts > 1 ->
        attempt(id, opts, fun, attempts - 1)

      {:error, :daemon_lock_set_changed} ->
        {:error, if(Repo.in_transaction?(), do: :daemon_lock_set_changed, else: :busy)}

      result ->
        result
    end
  end

  defp lock_requested_members(id, opts, ids) do
    if opts[:members] do
      case Repo.get(Daemon, id) do
        nil -> :ok
        daemon -> lock_members(daemon.user_id, ids)
      end
    end
  end

  def workspace_ids(id, opts) do
    served =
      Repo.all(from w in DaemonWorkspace, where: w.daemon_id == ^id, select: w.workspace_id)

    existing =
      Repo.all(
        from r in Runtime, where: r.daemon_id == ^id, select: r.workspace_id, distinct: true
      )

    Enum.sort(Enum.uniq(served ++ existing ++ Keyword.get(opts, :workspace_ids, [])))
  end

  def lock_members(user_id, ids) do
    Repo.all(
      from m in Membership,
        where: m.user_id == ^user_id and m.workspace_id in ^ids,
        order_by: m.workspace_id,
        lock: "FOR SHARE"
    )
  end

  if Mix.env() == :test do
    def hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _ -> :ok
      end
    end

    defp check_busy! do
      count = Application.get_env(:helmsman, :daemon_locked_force_busy, 0)

      if count > 0 do
        Application.put_env(:helmsman, :daemon_locked_force_busy, count - 1)
        Repo.rollback(:busy)
      else
        :ok
      end
    end
  else
    def hook(_), do: :ok
    defp check_busy!, do: :ok
  end
end
