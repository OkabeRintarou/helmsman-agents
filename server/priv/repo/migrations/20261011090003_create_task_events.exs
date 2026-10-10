defmodule Helmsman.Repo.Migrations.CreateTaskEvents do
  use Ecto.Migration

  def change do
    # Append-only task history.
    create table(:task_events) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false

      add :task_id,
          references(:tasks, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      add :from_status, :text
      add :to_status, :text, null: false

      add :actor_id,
          references(:actors, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      add :comment, :text

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:task_events, [:task_id, :inserted_at])

    create constraint(:task_events, :task_events_status_check,
             check:
               "(from_status IS NULL OR from_status IN " <>
                 "('new', 'in_progress', 'done', 'verified', 'rejected', 'cancelled')) AND " <>
                 "to_status IN ('new', 'in_progress', 'done', 'verified', 'rejected', 'cancelled')"
           )
  end
end
