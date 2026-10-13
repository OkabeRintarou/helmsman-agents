defmodule Helmsman.Squads.Member do
  @moduledoc """
  A member of a squad (`add-squads` decision 2): a person or a managed
  agent with a note on its role, at `position` in the squad's list. The
  leader is never a member.
  """

  use Ecto.Schema

  alias Helmsman.Actors.Actor
  alias Helmsman.Squads.Squad
  alias Helmsman.Workspaces.Workspace

  @type t :: %__MODULE__{}

  @primary_key false
  schema "squad_members" do
    belongs_to :workspace, Workspace
    belongs_to :squad, Squad, primary_key: true
    belongs_to :actor, Actor, primary_key: true
    field :role_note, :string, default: ""
    field :position, :integer
    field :inserted_at, :utc_datetime_usec
  end
end
