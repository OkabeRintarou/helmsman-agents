defmodule Helmsman.Workspaces.Membership do
  @moduledoc """
  A user's membership of a workspace and their role in it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Helmsman.Accounts.User
  alias Helmsman.Workspaces.Workspace

  @type role :: :owner | :admin | :member | :viewer
  @type t :: %__MODULE__{}

  @roles [:owner, :admin, :member, :viewer]

  schema "memberships" do
    belongs_to :workspace, Workspace
    belongs_to :user, User
    field :role, Ecto.Enum, values: @roles

    timestamps(type: :utc_datetime)
  end

  @doc "All roles, from highest to lowest."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc """
  Changeset for a new membership; `workspace_id` and `user_id` are set by
  the caller, not cast from attrs.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role])
    |> validate_required([:workspace_id, :user_id, :role])
    |> unique_constraint([:workspace_id, :user_id],
      name: :memberships_workspace_id_user_id_index,
      message: "is already a member"
    )
    |> check_constraint(:role, name: :memberships_role_check, message: "is invalid")
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
  end
end
