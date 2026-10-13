defmodule Helmsman.Actors.Claim do
  @moduledoc "A member's request to merge an unclaimed human identity into their own."
  use Ecto.Schema
  import Ecto.Changeset

  schema "actor_claims" do
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    belongs_to :actor, Helmsman.Actors.Actor
    belongs_to :user, Helmsman.Accounts.User

    field :status, Ecto.Enum,
      values: [:pending, :approved, :rejected, :cancelled],
      default: :pending

    belongs_to :decided_by, Helmsman.Accounts.User
    field :decided_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:workspace_id, :actor_id, :user_id, :status, :decided_by_id, :decided_at])
    |> validate_required([:workspace_id, :actor_id, :user_id, :status])
    |> unique_constraint(:actor_id, name: :actor_claims_pending)
  end
end
