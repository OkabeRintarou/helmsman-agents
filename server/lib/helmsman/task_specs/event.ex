defmodule Helmsman.TaskSpecs.Event do
  @moduledoc """
  An audit event of a spec (`add-spec-workflow` decision 6), numbered
  within the spec. Insert only; replaying them gives the spec's mutable
  state (`Helmsman.TaskSpecs.State.replay/2`).
  """

  use Ecto.Schema

  alias Helmsman.Actors.Actor
  alias Helmsman.Runs.Run

  @type t :: %__MODULE__{}

  @actions ~w(created change_id_changed version_submitted review_requested
              review_request_closed review_submitted finalize_proposed proposal_withdrawn
              approved finalized proposal_rejected abandoned reopened)

  schema "task_spec_events" do
    field :workspace_id, :id
    field :spec_id, :id
    field :number, :integer
    belongs_to :actor, Actor
    belongs_to :source_run, Run
    field :action, :string
    field :version, :integer
    field :data, :map, default: %{}
    field :inserted_at, :utc_datetime_usec
  end

  @doc "The audit actions."
  @spec actions() :: [String.t()]
  def actions, do: @actions
end
