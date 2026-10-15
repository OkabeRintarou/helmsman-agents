defmodule Helmsman.Dispatch.Workers.DependencySweep do
  @moduledoc """
  Every ten minutes (`config.exs` crontab): releases or cancels the runs
  deferred by a dependency that neither path of
  `Helmsman.Dispatch.Dependencies` reached (`add-dependency-dispatch`
  decision 9, `Helmsman.Dispatch.Dependencies.sweep/0`).
  """

  use Oban.Worker, queue: :default, unique: [period: 300]

  alias Helmsman.Dispatch.Dependencies
  alias Helmsman.Squads.EpicWatch

  @impl true
  def perform(%Oban.Job{}) do
    _count = Dependencies.sweep()
    # `improve-squad-leader-orchestration` decision 11: the epics that may
    # be stalled, oldest check first.
    _checks = EpicWatch.sweep()
    :ok
  end
end
