defmodule Helmsman.Squads.EpicWatchCheck do
  @moduledoc """
  The last stall check of an epic (`improve-squad-leader-orchestration`
  decisions 2, 11): when and with which result. Only for the fair rotation
  of the sweep; runtime state, never exported.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "epic_watch_checks" do
    field :workspace_id, :id
    field :epic_id, :id
    field :checked_at, :utc_datetime_usec
    field :result, :string
  end
end
