defmodule Helmsman.Repo.Migrations.AddSquadOrchestration do
  use Ecto.Migration

  # `improve-squad-leader-orchestration` decision 2: the orchestration root
  # recorded on the `requested` grant of a task a squad leader created
  # outside any epic, and the last stall check of each epic (the fair
  # rotation of the sweep, decision 11).
  def up do
    alter table(:task_grants) do
      add :root_task_id,
          references(:tasks, with: [workspace_id: :workspace_id], on_delete: :delete_all)
    end

    create index(:task_grants, [:squad_id, :root_task_id],
             where: "kind = 'requested' AND root_task_id IS NOT NULL",
             name: :task_grants_orchestration_root_index
           )

    create index(:task_grants, [:root_task_id], where: "root_task_id IS NOT NULL")

    create table(:epic_watch_checks) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :epic_id,
          references(:tasks, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false

      add :checked_at, :utc_datetime_usec, null: false
      add :result, :text, null: false
    end

    create unique_index(:epic_watch_checks, [:epic_id])
    create index(:epic_watch_checks, [:checked_at])

    # Decision 3: the `orchestrate` capability.
    execute(
      "ALTER TABLE runs DROP CONSTRAINT runs_capabilities_check, ADD CONSTRAINT " <>
        "runs_capabilities_check CHECK (capabilities <@ " <>
        "ARRAY['read','write_task','create_tasks','delegate','design','orchestrate']::text[])"
    )
  end

  # Development rollback only: runs with the capability lose it.
  def down do
    execute(
      "UPDATE runs SET capabilities = array_remove(capabilities, 'orchestrate') " <>
        "WHERE 'orchestrate' = ANY(capabilities)"
    )

    execute(
      "ALTER TABLE runs DROP CONSTRAINT runs_capabilities_check, ADD CONSTRAINT " <>
        "runs_capabilities_check CHECK (capabilities <@ " <>
        "ARRAY['read','write_task','create_tasks','delegate','design']::text[])"
    )

    drop table(:epic_watch_checks)
    drop index(:task_grants, [:root_task_id], where: "root_task_id IS NOT NULL")

    drop index(:task_grants, [:squad_id, :root_task_id],
           name: :task_grants_orchestration_root_index
         )

    alter table(:task_grants) do
      remove :root_task_id
    end
  end
end
