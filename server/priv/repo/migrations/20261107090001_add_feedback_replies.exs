defmodule Helmsman.Repo.Migrations.AddFeedbackReplies do
  use Ecto.Migration

  def change do
    alter table(:feedback) do
      add :reply_to_seq,
          references(:feedback,
            column: :seq,
            type: :integer,
            with: [task_id: :task_id],
            on_delete: :restrict
          )

      add :reply_root_seq,
          references(:feedback,
            column: :seq,
            type: :integer,
            with: [task_id: :task_id],
            on_delete: :restrict
          )
    end

    create constraint(:feedback, :feedback_reply_check,
             check:
               "(reply_to_seq IS NULL AND reply_root_seq IS NULL) OR (reply_to_seq IS NOT NULL AND reply_root_seq IS NOT NULL AND reply_root_seq > 0 AND reply_root_seq <= reply_to_seq AND reply_to_seq < seq)"
           )

    create index(:feedback, [:task_id, :reply_root_seq])
  end
end
