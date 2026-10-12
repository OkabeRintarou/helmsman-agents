defmodule Helmsman.Repo.Migrations.CreateFeedback do
  use Ecto.Migration

  def change do
    # Append-only task feedback (designs/06). Rows are never deleted; a
    # revision inserts a new row and marks the old one superseded.
    create table(:feedback) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false

      add :task_id,
          references(:tasks, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      add :seq, :integer, null: false
      add :thread_seq, :integer, null: false

      add :author_id,
          references(:actors, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      add :kind, :text, null: false
      add :content, :text, null: false
      add :mentions, {:array, :bigint}, null: false, default: []
      add :status, :text, null: false, default: "active"
      # The composite foreign keys to `feedback` itself are added below,
      # once the `(workspace_id, id)` index they reference exists.
      add :supersedes_id, :bigint
      add :superseded_by_id, :bigint

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:feedback, [:task_id, :seq])
    create unique_index(:feedback, [:workspace_id, :id])

    # A record is revised at most once: no forks in a revision chain.
    create unique_index(:feedback, [:supersedes_id], where: "supersedes_id IS NOT NULL")

    create index(:feedback, [:task_id, :status, :thread_seq])

    alter table(:feedback) do
      modify :supersedes_id,
             references(:feedback, with: [workspace_id: :workspace_id], on_delete: :restrict),
             from: :bigint

      modify :superseded_by_id,
             references(:feedback, with: [workspace_id: :workspace_id], on_delete: :restrict),
             from: :bigint
    end

    create constraint(:feedback, :feedback_kind_check,
             check: "kind IN ('comment', 'review', 'question', 'answer')"
           )

    create constraint(:feedback, :feedback_status_check,
             check: "status IN ('active', 'superseded')"
           )

    create constraint(:feedback, :feedback_superseded_check,
             check: "(status = 'superseded') = (superseded_by_id IS NOT NULL)"
           )

    create constraint(:feedback, :feedback_content_size,
             check: "octet_length(content) BETWEEN 1 AND 65536"
           )

    create constraint(:feedback, :feedback_thread_seq_check,
             check: "thread_seq >= 1 AND thread_seq <= seq"
           )
  end
end
