defmodule Helmsman.Repo.Migrations.AddPushColumnsToRuns do
  use Ecto.Migration

  # `add-daemon-git-workspace` decision 1: the push record of a run. No
  # `task_branches` table: the task branch is derived from the workspace
  # and the task, the rest is read from the runs.
  def change do
    alter table(:runs) do
      add :repository_id, references(:repositories, with: [workspace_id: :workspace_id])
      add :branch, :text
      add :base_sha, :text
      add :head_sha, :text
      add :push_status, :text, null: false, default: "none"
      add :rescue_branch, :text
      add :push_commits, :jsonb
      add :pushed_at, :utc_datetime_usec
    end

    create constraint(:runs, :runs_push_status_check,
             check: "push_status IN ('none','pushed','conflict','failed')"
           )

    create constraint(:runs, :runs_push_record_check,
             check:
               "(push_status IN ('pushed','conflict')) = " <>
                 "(head_sha IS NOT NULL AND base_sha IS NOT NULL AND pushed_at IS NOT NULL)"
           )

    create constraint(:runs, :runs_rescue_branch_check,
             check: "(push_status = 'conflict') = (rescue_branch IS NOT NULL)"
           )

    create index(:runs, [:task_id, :id],
             where: "push_status IN ('pushed','conflict')",
             name: :runs_pushed_index
           )
  end
end
