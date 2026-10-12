defmodule Helmsman.Runs.RunEvent do
  @moduledoc """
  One execution event of a run (designs/13 §1): its sequence number in the
  run, the `HelmsmanProtocol.Event` type and its data in wire form
  (string keys). Rows are only inserted, and deleted with every other
  event of the run 30 days after it ended (`Helmsman.Runs.Workers.PruneEvents`).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "run_events" do
    belongs_to :run, Helmsman.Runs.Run, primary_key: true
    field :seq, :integer, primary_key: true
    field :type, :string
    field :data, :map
    field :at, :utc_datetime_usec
  end
end
