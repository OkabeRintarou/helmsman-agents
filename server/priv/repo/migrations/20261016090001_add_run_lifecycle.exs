defmodule Helmsman.Repo.Migrations.AddRunLifecycle do
  use Ecto.Migration

  # `HelmsmanProtocol.Event.types/0` when this migration was written; a
  # later protocol version that adds a type changes the constraint itself.
  @event_types ~w(text thinking tool_call tool_result usage session result error status)

  def change do
    alter table(:runs) do
      add :daemon_id, references(:daemons)
      add :attempt, :smallint, null: false, default: 1
      add :auto_retries, :smallint, null: false, default: 0
      add :retry_of_id, references(:runs, with: [workspace_id: :workspace_id])

      add :not_before, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :session_id, :text
      add :summary, :text
      add :usage, :jsonb
      add :error, :text
      add :events_seq, :integer, null: false, default: 0
      add :cancel_requested_by_id, references(:actors, with: [workspace_id: :workspace_id])
      add :claimed_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :last_event_at, :utc_datetime_usec
      add :events_pruned_at, :utc_datetime_usec
    end

    create unique_index(:runs, [:retry_of_id], where: "retry_of_id IS NOT NULL")
    create index(:runs, [:daemon_id, :status])

    create index(:runs, [:workspace_id, :root_initiator_user_id],
             where: "status IN ('deferred','queued','claimed','running')",
             name: :runs_initiator_open_index
           )

    create index(:runs, [:finished_at],
             where: "events_pruned_at IS NULL AND finished_at IS NOT NULL",
             name: :runs_events_unpruned_index
           )

    drop index(:runs, [:runtime_id, :status, "priority DESC", :inserted_at, :id])

    create index(:runs, [:runtime_id, :status, "priority DESC", :not_before, :inserted_at, :id],
             name: :runs_claim_index
           )

    create constraint(:runs, :runs_summary_size, check: "octet_length(summary) <= 4096")
    create constraint(:runs, :runs_error_size, check: "octet_length(error) <= 16384")
    create constraint(:runs, :runs_attempt_check, check: "attempt >= 1")
    create constraint(:runs, :runs_auto_retries_check, check: "auto_retries >= 0")
    create constraint(:runs, :runs_events_seq_check, check: "events_seq >= 0")

    # Not partitioned (designs/00 §9.5): the primary key must be
    # `(run_id, seq)` for deduplication, and a run's events are deleted as
    # a block through its prefix.
    create table(:run_events, primary_key: false) do
      add :run_id, references(:runs, on_delete: :delete_all), primary_key: true
      add :seq, :integer, primary_key: true
      add :type, :text, null: false
      add :data, :jsonb, null: false
      add :at, :utc_datetime_usec, null: false
    end

    create constraint(:run_events, :run_events_type_check,
             check: "type IN (#{Enum.map_join(@event_types, ",", &"'#{&1}'")})"
           )

    create constraint(:run_events, :run_events_seq_check, check: "seq >= 1")

    alter table(:feedback) do
      add :fallback, :boolean, null: false, default: false
    end

    create unique_index(:feedback, [:source_run_id],
             where: "fallback",
             name: :feedback_fallback_run_index
           )

    create unique_index(:task_events, [:source_run_id],
             where: "auto AND from_status = 'new' AND to_status = 'in_progress'",
             name: :task_events_auto_claim_run_index
           )
  end
end
