defmodule Helmsman.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false
      add :key, :text, null: false
      add :name, :text, null: false
      add :description, :text, null: false, default: ""
      add :task_seq, :integer, null: false, default: 0
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:workspace_id, :key])
    create unique_index(:projects, [:workspace_id, :id])

    create constraint(:projects, :projects_key_format, check: "key ~ '^[A-Z][A-Z0-9]{1,9}$'")

    create constraint(:projects, :projects_name_length,
             check: "char_length(name) BETWEEN 1 AND 80"
           )

    create constraint(:projects, :projects_description_size,
             check: "octet_length(description) <= 65536"
           )

    create constraint(:projects, :projects_task_seq_check, check: "task_seq >= 0")
  end
end
