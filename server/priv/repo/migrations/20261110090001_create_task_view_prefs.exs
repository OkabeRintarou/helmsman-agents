defmodule Helmsman.Repo.Migrations.CreateTaskViewPrefs do
  use Ecto.Migration

  def change do
    create table(:task_view_prefs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :view, :text, null: false, default: "list"
      add :hidden_columns, {:array, :text}, null: false, default: ["rejected", "cancelled"]
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:task_view_prefs, [:workspace_id, :user_id])

    create constraint(:task_view_prefs, :task_view_prefs_view_check,
             check: "view IN ('list', 'board')"
           )

    create constraint(:task_view_prefs, :task_view_prefs_hidden_columns_check,
             check:
               "hidden_columns <@ ARRAY['new','in_progress','done','verified','rejected','cancelled']::text[]"
           )

    create index(:tasks, [:project_id, :status, "updated_at DESC", "id DESC"],
             name: :tasks_project_id_status_updated_at_id_index
           )
  end
end
