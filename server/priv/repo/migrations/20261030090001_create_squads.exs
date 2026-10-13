defmodule Helmsman.Repo.Migrations.CreateSquads do
  use Ecto.Migration

  # `add-squads` decision 2: squads and their members, the squad a run
  # works as, the squad of a grant, the assignee side recorded on a move to
  # `verified`, and squad creation conversations.
  def up do
    create table(:squads) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :actor_id, references(:actors, with: [workspace_id: :workspace_id]), null: false

      add :leader_agent_id,
          references(:actors, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      add :description, :text, null: false, default: ""
      add :instructions, :text, null: false, default: ""
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:squads, [:actor_id])
    create unique_index(:squads, [:workspace_id, :id])
    create index(:squads, [:leader_agent_id])

    create constraint(:squads, :squads_description_length,
             check: "octet_length(description) <= 2048"
           )

    create constraint(:squads, :squads_instructions_length,
             check: "octet_length(instructions) <= 16384"
           )

    create table(:squad_members, primary_key: false) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :squad_id,
          references(:squads, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false,
          primary_key: true

      add :actor_id, references(:actors, with: [workspace_id: :workspace_id]),
        null: false,
        primary_key: true

      add :role_note, :text, null: false, default: ""
      add :position, :smallint, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:squad_members, [:actor_id])

    create constraint(:squad_members, :squad_members_role_note_length,
             check: "octet_length(role_note) <= 2048"
           )

    alter table(:runs) do
      add :squad_id, references(:squads, with: [workspace_id: :workspace_id])
    end

    create index(:runs, [:squad_id], where: "squad_id IS NOT NULL")

    execute("DROP INDEX runs_pending_index")

    execute(
      "CREATE UNIQUE INDEX runs_pending_index ON runs " <>
        "(task_id, agent_id, lane, coalesce(squad_id, 0)) " <>
        "WHERE status IN ('deferred','queued')"
    )

    alter table(:task_grants) do
      add :squad_id, references(:squads, with: [workspace_id: :workspace_id])
    end

    alter table(:task_events) do
      add :assignee_side_ids, {:array, :bigint}
    end

    execute(
      "ALTER TABLE agent_designs DROP CONSTRAINT agent_designs_kind_check, " <>
        "ADD CONSTRAINT agent_designs_kind_check CHECK (kind IN ('agent','squad'))"
    )
  end

  # Development rollback only: squad conversations and the pending runs
  # that work as a squad would break the narrower constraint and index.
  def down do
    execute("DELETE FROM agent_designs WHERE kind = 'squad'")

    execute(
      "ALTER TABLE agent_designs DROP CONSTRAINT agent_designs_kind_check, " <>
        "ADD CONSTRAINT agent_designs_kind_check CHECK (kind IN ('agent'))"
    )

    alter table(:task_events) do
      remove :assignee_side_ids
    end

    alter table(:task_grants) do
      remove :squad_id
    end

    execute("DELETE FROM runs WHERE squad_id IS NOT NULL AND status IN ('deferred','queued')")

    execute("DROP INDEX runs_pending_index")

    execute(
      "CREATE UNIQUE INDEX runs_pending_index ON runs (task_id, agent_id, lane) " <>
        "WHERE status IN ('deferred','queued')"
    )

    drop index(:runs, [:squad_id], where: "squad_id IS NOT NULL")

    alter table(:runs) do
      remove :squad_id
    end

    drop table(:squad_members)
    drop table(:squads)
  end
end
