defmodule Helmsman.Repo.Migrations.CreateMemberships do
  use Ecto.Migration

  def change do
    create table(:memberships) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :role, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:workspace_id, :user_id])
    create unique_index(:memberships, [:workspace_id, :id])
    create index(:memberships, [:user_id])

    create constraint(:memberships, :memberships_role_check,
             check: "role IN ('owner', 'admin', 'member', 'viewer')"
           )
  end
end
