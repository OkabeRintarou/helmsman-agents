defmodule Helmsman.Repo.Migrations.AddFeedbackColumnsToTasksAndEvents do
  use Ecto.Migration

  def change do
    # Maintained in the transaction that writes feedback, under the task
    # row lock (designs/06).
    alter table(:tasks) do
      add :feedback_seq, :integer, null: false, default: 0
      add :feedback_count, :integer, null: false, default: 0
      add :open_question, :boolean, null: false, default: false
    end

    # MATCH SIMPLE: only checked when feedback_id is set.
    alter table(:task_events) do
      add :feedback_id,
          references(:feedback, with: [workspace_id: :workspace_id], on_delete: :restrict)
    end
  end
end
