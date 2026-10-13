defmodule Helmsman.Repo.Migrations.CreateTaskPullRequests do
  use Ecto.Migration

  # `add-pr-reconcile-merge` decisions 2, 21, 22. `task_events.verified_sha`
  # (decision 15) is created and dropped by the earlier
  # `add-local-repositories` migration, which landed first; this one leaves
  # it alone so rolling it back keeps the column.
  @merge_reasons ~w(policy_manual agent_verified not_independent verified_sha_missing
                    verified_sha_not_pushed push_chain_broken run_active head_changed
                    ci_pending ci_timeout required_checks merge_rejected pr_closed
                    repository_unavailable branch_missing ci_failed_limit
                    merge_conflict_limit)

  def up do
    create table(:task_pull_requests) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false

      add :task_id,
          references(:tasks, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      add :repository_id,
          references(:repositories, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      add :number, :integer, null: false
      add :node_id, :text, null: false
      add :url, :text, null: false
      add :branch, :text, null: false
      add :base_branch, :text, null: false
      add :state, :text, null: false
      add :head_sha, :text
      add :checks_state, :text, null: false, default: "none"
      add :checks, :jsonb
      add :merge_status, :text, null: false, default: "none"
      add :merge_reason, :text
      add :merge_note, :text
      add :merged_sha, :text
      add :merged_at, :utc_datetime_usec
      add :included_sha, :text
      add :closed_by_helmsman, :boolean, null: false, default: false
      add :draft_supported, :boolean, null: false, default: true
      add :auto_reopen_count, :smallint, null: false, default: 0
      add :waiting_since, :utc_datetime_usec
      add :merge_request, :jsonb
      add :escalated_event_id, :bigint
      add :branch_deleted_at, :utc_datetime_usec
      add :rescue_cleaned_at, :utc_datetime_usec
      add :reconciled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:task_pull_requests, [:repository_id, :number])
    create unique_index(:task_pull_requests, [:workspace_id, :id])
    create index(:task_pull_requests, [:task_id, :id])

    create index(:task_pull_requests, [:repository_id, :head_sha],
             where: "state IN ('draft','open')",
             name: :task_pull_requests_open_head_index
           )

    create constraint(:task_pull_requests, :task_pull_requests_state_check,
             check: "state IN ('draft','open','merged','closed')"
           )

    create constraint(:task_pull_requests, :task_pull_requests_checks_state_check,
             check: "checks_state IN ('none','pending','success','failure')"
           )

    create constraint(:task_pull_requests, :task_pull_requests_merge_status_check,
             check: "merge_status IN ('none','waiting','stale','merged','blocked','failed')"
           )

    create constraint(:task_pull_requests, :task_pull_requests_merge_reason_check,
             check:
               "(merge_reason IS NULL OR merge_reason IN (#{Enum.map_join(@merge_reasons, ",", &"'#{&1}'")})) " <>
                 "AND (merge_status NOT IN ('blocked','failed','waiting','stale') " <>
                 "OR merge_reason IS NOT NULL)"
           )

    create constraint(:task_pull_requests, :task_pull_requests_merge_note_size,
             check: "merge_note IS NULL OR octet_length(merge_note) <= 1024"
           )
  end

  def down do
    drop table(:task_pull_requests)
  end
end
