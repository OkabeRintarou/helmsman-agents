defmodule Helmsman.Autopilots.Workers.Sweep do
  @moduledoc """
  The reconciliation of autopilots (`add-autopilots` decision 5), every
  ten minutes and once after the application starts: every enabled
  autopilot with a cron has a next time and its `Fire` job (unique, so an
  existing one is not duplicated), and every started record is settled.
  """

  use Oban.Worker, queue: :autopilots, max_attempts: 3, unique: [period: 60]

  import Ecto.Query

  alias Helmsman.Autopilots.{Autopilot, Clock, Record, Settle, State}
  alias Helmsman.Locks
  alias Helmsman.Repo
  alias Helmsman.Tx

  @impl true
  def perform(%Oban.Job{}) do
    ids =
      Repo.all(
        from(a in Autopilot,
          where: a.enabled and not is_nil(a.cron),
          order_by: a.id,
          select: a.id
        )
      )

    Enum.each(ids, &plan/1)

    Repo.all(
      from(r in Record, where: r.status == :started, distinct: true, select: r.autopilot_id)
    )
    |> Enum.each(&Settle.settle/1)

    :ok
  end

  defp plan(id) do
    {:ok, _} =
      Tx.run(fn ->
        with %Autopilot{workspace_id: ws} <- Repo.get(Autopilot, id),
             :ok <- Locks.maint_shared!(ws) do
          {:ok, plan_locked(State.lock(ws, id))}
        else
          nil -> {:ok, nil}
        end
      end)

    :ok
  end

  defp plan_locked(%Autopilot{enabled: true, cron: cron, next_run_at: nil} = a)
       when is_binary(cron),
       do: State.reschedule!(a, Clock.now())

  defp plan_locked(%Autopilot{enabled: true, cron: cron, next_run_at: at} = a)
       when is_binary(cron),
       do: State.plan!(a.id, at)

  defp plan_locked(_other), do: nil
end
