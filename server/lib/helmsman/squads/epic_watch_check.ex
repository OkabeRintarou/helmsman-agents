defmodule Helmsman.Squads.EpicWatchCheck do
  @moduledoc """
  The last stall check of an epic (`improve-squad-leader-orchestration`
  decisions 2, 11): when and with which result, for the fair rotation of
  the sweep; and the last wake of the leader (`woken_at`, its
  `wake_signature`, `wakes`: the wakes in a row with no progress between
  them), the history the dedupe and the cap read (decision 12). Written
  only under the epic's row lock; runtime state, never exported.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "epic_watch_checks" do
    field :workspace_id, :id
    field :epic_id, :id
    field :checked_at, :utc_datetime_usec
    field :result, :string
    field :woken_at, :utc_datetime_usec
    field :wake_signature, :string
    field :wakes, :integer, default: 0
  end
end
