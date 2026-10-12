defmodule Helmsman.Repo.Migrations.AddEpicsToTasks do
  use Ecto.Migration

  # `add-epics` decision 2. That `epic_id` points at a task of kind `epic`
  # cannot be expressed here: the write transactions check it.
  def change do
    alter table(:tasks) do
      add :kind, :text, null: false, default: "task"

      # MATCH SIMPLE: only checked when epic_id is set.
      add :epic_id,
          references(:tasks, with: [workspace_id: :workspace_id], on_delete: :restrict)
    end

    create constraint(:tasks, :tasks_kind_check, check: "kind IN ('task', 'epic')")
    create constraint(:tasks, :tasks_epic_not_nested, check: "kind <> 'epic' OR epic_id IS NULL")
    create constraint(:tasks, :tasks_epic_not_self, check: "epic_id IS NULL OR epic_id <> id")
    create index(:tasks, [:epic_id], where: "epic_id IS NOT NULL")
  end
end
