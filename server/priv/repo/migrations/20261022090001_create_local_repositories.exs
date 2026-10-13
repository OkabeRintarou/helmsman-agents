defmodule Helmsman.Repo.Migrations.CreateLocalRepositories do
  use Ecto.Migration

  # `add-local-repositories` decisions 4, 5, 6, 9 and 10.
  def up do
    create table(:local_repositories) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false
      add :daemon_id, references(:daemons, on_delete: :restrict), null: false
      add :name, :text, null: false
      # Only for display; visible to the daemon's owner and workspace owners / admins.
      add :path, :text, null: false
      add :default_branch, :text
      add :status, :text, null: false, default: "online"
      add :unavailable_reason, :text
      add :removed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:local_repositories, [:workspace_id, :daemon_id, :name])
    create unique_index(:local_repositories, [:workspace_id, :id])
    create index(:local_repositories, [:daemon_id])

    create constraint(:local_repositories, :local_repositories_status_check,
             check: "status IN ('online','offline','unavailable')"
           )

    create constraint(:local_repositories, :local_repositories_reason_check,
             check: "(status = 'unavailable') = (unavailable_reason IS NOT NULL)"
           )

    create table(:task_local_branches) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false

      add :task_id,
          references(:tasks, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      add :local_repository_id,
          references(:local_repositories,
            with: [workspace_id: :workspace_id],
            on_delete: :restrict
          ),
          null: false

      add :branch, :text, null: false
      add :head_sha, :text, null: false
      add :state, :text, null: false, default: "open"
      add :merged_at, :utc_datetime
      add :merged_by_id, references(:actors, with: [workspace_id: :workspace_id])
      add :merge_note, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_local_branches, [:task_id])
    create index(:task_local_branches, [:local_repository_id, :state, :updated_at])

    create constraint(:task_local_branches, :task_local_branches_state_check,
             check: "state IN ('open','merged')"
           )

    create constraint(:task_local_branches, :task_local_branches_merged_check,
             check:
               "(state = 'merged') = (merged_at IS NOT NULL) AND " <>
                 "(state = 'merged' OR (merged_by_id IS NULL AND merge_note IS NULL))"
           )

    create constraint(:task_local_branches, :task_local_branches_note_length,
             check: "merge_note IS NULL OR char_length(merge_note) <= 2000"
           )

    alter table(:projects) do
      add :local_repository_id,
          references(:local_repositories,
            with: [workspace_id: :workspace_id],
            on_delete: :restrict
          )
    end

    create index(:projects, [:local_repository_id])

    create constraint(:projects, :projects_one_repository_check,
             check: "num_nonnulls(repository_id, local_repository_id) <= 1"
           )

    alter table(:runs) do
      add :local_repository_id,
          references(:local_repositories, with: [workspace_id: :workspace_id])
    end

    create index(:runs, [:local_repository_id], where: "local_repository_id IS NOT NULL")

    create constraint(:runs, :runs_one_repository_check,
             check: "num_nonnulls(repository_id, local_repository_id) <= 1"
           )

    # Shared with `add-pr-reconcile-merge` (its decision 15): whichever is
    # merged first creates the column.
    alter table(:task_events) do
      add_if_not_exists :verified_sha, :text
    end
  end

  def down do
    alter table(:task_events) do
      remove_if_exists :verified_sha, :text
    end

    drop constraint(:runs, :runs_one_repository_check)
    drop index(:runs, [:local_repository_id])

    alter table(:runs) do
      remove :local_repository_id
    end

    drop constraint(:projects, :projects_one_repository_check)
    drop index(:projects, [:local_repository_id])

    alter table(:projects) do
      remove :local_repository_id
    end

    drop table(:task_local_branches)
    drop table(:local_repositories)
  end
end
