defmodule Helmsman.Runs.Workers.Sweep do
  @moduledoc """
  Every minute (decision 16): ends the runs whose daemon will not report
  any more.

    * `claimed` for over 10 minutes → `failed` (`lease_expired`);
    * `claimed` or `running` while the daemon is revoked or silent for 2
      minutes → `failed` (`runtime_offline`); `cancelling` → `cancelled`
      (keeping its failure reason).

  A failed run gets its automatic retry job. Candidates are read without
  locks; each one is then judged again in its own transaction, daemon row
  `FOR SHARE`, then run row `FOR UPDATE`, so a report that committed
  meanwhile wins.
  """

  use Oban.Worker, queue: :runs

  import Ecto.Query

  alias Helmsman.Daemons
  alias Helmsman.Daemons.{Daemon, Locking}
  alias Helmsman.Repo
  alias Helmsman.Runs.{Lifecycle, Run}
  alias Helmsman.Tx

  @lease_seconds 600
  @silence_seconds 120

  @impl true
  def perform(_job) do
    ids = candidates()
    Locking.hook(:sweep_candidates)
    Enum.each(ids, &sweep/1)
    :ok
  end

  defp candidates do
    lease = lease_cutoff()
    silence = silence_cutoff()

    Repo.all(
      from(r in Run,
        join: d in Daemon,
        on: d.id == r.daemon_id,
        where: r.status in ^Run.active_statuses(),
        where:
          (r.status == :claimed and r.claimed_at < ^lease) or not is_nil(d.revoked_at) or
            d.last_seen_at < ^silence or is_nil(d.last_seen_at),
        order_by: r.id,
        select: r.id
      )
    )
  end

  defp lease_cutoff, do: DateTime.add(DateTime.utc_now(), -@lease_seconds, :second)
  defp silence_cutoff, do: DateTime.add(Daemons.now(), -@silence_seconds, :second)

  defp sweep(run_id) do
    Tx.run(fn ->
      daemon_id = Repo.one(from(r in Run, where: r.id == ^run_id, select: r.daemon_id))
      daemon = Repo.one(from(d in Daemon, where: d.id == ^daemon_id, lock: "FOR SHARE"))
      run = Repo.one!(from(r in Run, where: r.id == ^run_id, lock: "FOR UPDATE"))

      if run.status in Run.active_statuses() and run.daemon_id == daemon_id,
        do: judge(run, daemon)

      {:ok, :ok}
    end)
  end

  defp judge(run, daemon) do
    cond do
      offline?(daemon) and run.status == :cancelling ->
        Lifecycle.end!(run, :cancelled)

      offline?(daemon) ->
        run
        |> Lifecycle.end!(:failed, failure_reason: :runtime_offline)
        |> Lifecycle.maybe_retry()

      run.status == :claimed and DateTime.compare(run.claimed_at, lease_cutoff()) == :lt ->
        run |> Lifecycle.end!(:failed, failure_reason: :lease_expired) |> Lifecycle.maybe_retry()

      true ->
        :ok
    end
  end

  defp offline?(nil), do: true
  defp offline?(%Daemon{revoked_at: %DateTime{}}), do: true
  defp offline?(%Daemon{last_seen_at: nil}), do: true

  defp offline?(%Daemon{last_seen_at: seen}),
    do: DateTime.compare(seen, silence_cutoff()) == :lt
end
