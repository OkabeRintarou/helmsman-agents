defmodule Helmsman.Daemons.Workers.MarkOffline do
  @moduledoc """
  Every minute (decision 12): sets the runtimes of revoked daemons and of
  daemons silent for 2 minutes offline. Candidates are read without locks;
  each one is then rechecked under `Helmsman.Daemons.locked/3`, so a report
  that arrived meanwhile wins. A candidate whose lock set keeps changing
  (`:busy`) is left to the next run.
  """

  use Oban.Worker, queue: :daemons

  import Ecto.Query

  alias Helmsman.Daemons
  alias Helmsman.Daemons.Daemon
  alias Helmsman.Daemons.Locking
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Events
  alias Helmsman.Repo

  @silence_seconds 120

  @impl true
  def perform(_job) do
    cutoff = DateTime.add(Daemons.now(), -@silence_seconds)
    ids = candidates(cutoff)
    Locking.hook(:daemon_offline_candidates)
    Enum.each(ids, &mark(&1, cutoff))
    :ok
  end

  defp candidates(cutoff) do
    Repo.all(
      from d in Daemon,
        as: :daemon,
        where: not is_nil(d.revoked_at) or d.last_seen_at < ^cutoff,
        where:
          exists(
            from r in Runtime,
              where: r.daemon_id == parent_as(:daemon).id and r.status == "online"
          ),
        select: d.id
    )
  end

  defp mark(id, cutoff) do
    Daemons.locked(id, [], fn daemon, workspace_ids ->
      if offline?(daemon, cutoff) do
        Daemons.offline(id, workspace_ids)
        Events.after_commit(Events.topic(:daemon, id), {:daemon_config_changed})
      end

      {:ok, :ok}
    end)
  end

  defp offline?(%Daemon{revoked_at: %DateTime{}}, _cutoff), do: true
  defp offline?(%Daemon{last_seen_at: nil}, _cutoff), do: false
  defp offline?(daemon, cutoff), do: DateTime.compare(daemon.last_seen_at, cutoff) == :lt
end
