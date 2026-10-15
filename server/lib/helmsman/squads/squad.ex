defmodule Helmsman.Squads.Squad do
  @moduledoc """
  A squad (`add-squads` decision 2): the `kind = squad` identity `actor`,
  its leader (a managed agent), a description, Markdown instructions and
  an ordered list of members (`Helmsman.Squads.Member`). Disabling a squad
  disables its identity; there is no column of its own.
  """

  use Ecto.Schema

  alias Helmsman.Actors.Actor
  alias Helmsman.Squads.Member
  alias Helmsman.Workspaces.Workspace

  @type t :: %__MODULE__{}

  schema "squads" do
    belongs_to :workspace, Workspace
    belongs_to :actor, Actor
    belongs_to :leader_agent, Actor
    field :description, :string, default: ""
    field :instructions, :string, default: ""
    # `add-spec-workflow` decision 7: nil inherits the project's value.
    field :spec_finalize, Ecto.Enum, values: [:approval, :leader]
    field :lock_version, :integer, default: 1
    has_many :members, Member, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end
end
