defmodule Helmsman.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false

      add :project_id,
          references(:projects, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      add :seq, :integer, null: false
      add :ident, :text, null: false
      add :title, :text, null: false
      add :description, :text, null: false, default: ""
      add :status, :text, null: false, default: "new"
      add :priority, :text, null: false, default: "medium"
      add :labels, {:array, :text}, null: false, default: []

      add :created_by_id,
          references(:actors, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      # MATCH SIMPLE: only checked when assignee_id is set.
      add :assignee_id,
          references(:actors, with: [workspace_id: :workspace_id], on_delete: :restrict)

      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tasks, [:project_id, :seq])
    create unique_index(:tasks, [:workspace_id, :ident])
    create unique_index(:tasks, [:workspace_id, :id])
    create index(:tasks, [:labels], using: :gin)
    create index(:tasks, [:workspace_id, :status])
    create index(:tasks, ["workspace_id", "updated_at DESC"])
    create index(:tasks, [:assignee_id])

    # All six values now, so the state machine needs no constraint change.
    create constraint(:tasks, :tasks_status_check,
             check:
               "status IN ('new', 'in_progress', 'done', 'verified', 'rejected', 'cancelled')"
           )

    create constraint(:tasks, :tasks_priority_check,
             check: "priority IN ('low', 'medium', 'high')"
           )

    create constraint(:tasks, :tasks_title_length, check: "char_length(title) BETWEEN 1 AND 200")

    create constraint(:tasks, :tasks_description_size,
             check: "octet_length(description) <= 65536"
           )

    create constraint(:tasks, :tasks_labels_count, check: "cardinality(labels) <= 20")
  end
end
