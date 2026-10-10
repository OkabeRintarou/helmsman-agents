defmodule Helmsman.Repo.Migrations.CreateActors do
  use Ecto.Migration

  def change do
    create table(:actors) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false
      add :kind, :text, null: false
      add :name, :citext, null: false
      add :user_id, references(:users, on_delete: :restrict)
      add :owner_id, references(:users, on_delete: :restrict)
      add :disabled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:actors, [:workspace_id, :name])
    create unique_index(:actors, [:workspace_id, :id])

    create unique_index(:actors, [:workspace_id, :user_id],
             where: "kind = 'human'",
             name: :actors_one_human_per_user_index
           )

    create unique_index(:actors, [:workspace_id],
             where: "kind = 'system'",
             name: :actors_one_system_per_workspace_index
           )

    create constraint(:actors, :actors_kind_check,
             check: "kind IN ('human', 'agent', 'squad', 'system')"
           )

    # citext overrides `~` to be case-insensitive; compare as text.
    create constraint(:actors, :actors_name_format,
             check: "name::text ~ '^[a-z0-9][a-z0-9._/-]{0,63}$'"
           )

    create constraint(:actors, :actors_agent_owner_check,
             check: "(kind = 'agent') = (owner_id IS NOT NULL)"
           )

    create constraint(:actors, :actors_user_only_human_check,
             check: "kind = 'human' OR user_id IS NULL"
           )

    create constraint(:actors, :actors_reserved_name_check,
             check: "name <> 'helmsman' OR kind = 'system'"
           )
  end
end
