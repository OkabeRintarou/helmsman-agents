defmodule Helmsman.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    create table(:invitations) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false
      # NULL = a generic link anyone holding it may use.
      add :email, :citext
      add :role, :text, null: false
      add :token_hash, :binary, null: false
      add :invited_by_id, references(:users, on_delete: :restrict), null: false
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime
      add :accepted_by_id, references(:users, on_delete: :restrict)
      add :revoked_at, :utc_datetime
      add :revoked_by_id, references(:users, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:token_hash])
    create unique_index(:invitations, [:workspace_id, :id])

    create index(:invitations, [:workspace_id],
             where: "accepted_at IS NULL AND revoked_at IS NULL",
             name: :invitations_pending_index
           )

    create constraint(:invitations, :invitations_role_check,
             check: "role IN ('owner', 'admin', 'member', 'viewer')"
           )

    create constraint(:invitations, :invitations_accepted_or_revoked_check,
             check: "NOT (accepted_at IS NOT NULL AND revoked_at IS NOT NULL)"
           )
  end
end
