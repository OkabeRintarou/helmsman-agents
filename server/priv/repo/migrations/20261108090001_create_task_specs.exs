defmodule Helmsman.Repo.Migrations.CreateTaskSpecs do
  use Ecto.Migration

  # `add-spec-workflow` decision 2: a task's spec, its append-only versions
  # (files deduplicated by blob), review requests, reviews, issues with their
  # discussion and the audit events, plus the spec finalize mode of projects
  # and squads. Every reference is a composite foreign key with
  # `workspace_id` (designs/01 §3).
  def up do
    create table(:task_specs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :task_id,
          references(:tasks, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false

      add :change_id, :text, null: false
      add :status, :text, null: false, default: "draft"
      add :latest_version, :integer, null: false, default: 0
      add :final_version, :integer
      add :proposal_version, :integer
      add :proposal_summary, :text
      add :proposal_by_id, references(:actors, with: [workspace_id: :workspace_id])

      add :proposal_run_id,
          references(:runs,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:proposal_run_id]}
          )

      add :proposed_at, :utc_datetime_usec
      add :request_seq, :integer, null: false, default: 0
      add :review_seq, :integer, null: false, default: 0
      add :event_seq, :integer, null: false, default: 0
      add :created_by_id, references(:actors, with: [workspace_id: :workspace_id]), null: false
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:task_specs, [:workspace_id, :id])
    create unique_index(:task_specs, [:task_id])
    create unique_index(:task_specs, [:workspace_id, :change_id])

    create constraint(:task_specs, :task_specs_status_check,
             check: "status IN ('draft','in_review','pending_approval','finalized','abandoned')"
           )

    create constraint(:task_specs, :task_specs_change_id_format,
             check: "change_id ~ '^[a-z0-9][a-z0-9-]{1,63}$'"
           )

    create constraint(:task_specs, :task_specs_final_version_check,
             check: "(status = 'finalized') = (final_version IS NOT NULL)"
           )

    create constraint(:task_specs, :task_specs_proposal_check,
             check: "(status = 'pending_approval') = (proposal_version IS NOT NULL)"
           )

    create constraint(:task_specs, :task_specs_proposal_summary_length,
             check: "octet_length(proposal_summary) <= 16384"
           )

    create table(:task_spec_blobs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :spec_id,
          references(:task_specs, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false

      add :sha256, :binary, null: false
      add :content, :text, null: false
      add :bytes, :integer, null: false
    end

    create unique_index(:task_spec_blobs, [:workspace_id, :id])
    create unique_index(:task_spec_blobs, [:spec_id, :sha256])

    create table(:task_spec_versions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :spec_id,
          references(:task_specs, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false

      add :number, :integer, null: false
      add :author_id, references(:actors, with: [workspace_id: :workspace_id]), null: false

      add :source_run_id,
          references(:runs,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:source_run_id]}
          )

      add :note, :text, null: false, default: ""
      add :validation, :map, null: false, default: %{}
      add :valid, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:task_spec_versions, [:workspace_id, :id])
    create unique_index(:task_spec_versions, [:spec_id, :number])

    create constraint(:task_spec_versions, :task_spec_versions_note_length,
             check: "octet_length(note) <= 4096"
           )

    create table(:task_spec_files, primary_key: false) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :version_id,
          references(:task_spec_versions,
            with: [workspace_id: :workspace_id],
            on_delete: :delete_all
          ),
          null: false,
          primary_key: true

      add :path, :text, null: false, primary_key: true

      # Blobs and versions only go away with their spec (a cascade from the
      # task); the cascades keep the deletion order irrelevant.
      add :blob_id,
          references(:task_spec_blobs,
            with: [workspace_id: :workspace_id],
            on_delete: :delete_all
          ),
          null: false
    end

    create index(:task_spec_files, [:blob_id])

    create table(:task_spec_reviews) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :spec_id,
          references(:task_specs, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false

      add :number, :integer, null: false

      add :version_id,
          references(:task_spec_versions,
            with: [workspace_id: :workspace_id],
            on_delete: :delete_all
          ),
          null: false

      add :reviewer_id, references(:actors, with: [workspace_id: :workspace_id]), null: false

      add :source_run_id,
          references(:runs,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:source_run_id]}
          )

      add :verdict, :text, null: false
      add :summary, :text, null: false, default: ""
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:task_spec_reviews, [:workspace_id, :id])
    create unique_index(:task_spec_reviews, [:spec_id, :number])
    create index(:task_spec_reviews, [:version_id])

    create constraint(:task_spec_reviews, :task_spec_reviews_verdict_check,
             check: "verdict IN ('pass','fail','comment')"
           )

    create constraint(:task_spec_reviews, :task_spec_reviews_summary_length,
             check: "octet_length(summary) <= 16384"
           )

    create table(:task_spec_review_requests) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :spec_id,
          references(:task_specs, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false

      add :number, :integer, null: false

      add :version_id,
          references(:task_spec_versions,
            with: [workspace_id: :workspace_id],
            on_delete: :delete_all
          ),
          null: false

      add :reviewer_id, references(:actors, with: [workspace_id: :workspace_id]), null: false

      add :requested_by_id, references(:actors, with: [workspace_id: :workspace_id]), null: false

      add :request_run_id,
          references(:runs,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:request_run_id]}
          )

      add :note, :text, null: false, default: ""
      add :status, :text, null: false, default: "requested"
      add :close_reason, :text

      add :review_id,
          references(:task_spec_reviews,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:review_id]}
          )

      add :closed_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:task_spec_review_requests, [:workspace_id, :id])
    create unique_index(:task_spec_review_requests, [:spec_id, :number])

    create unique_index(:task_spec_review_requests, [:version_id, :reviewer_id],
             where: "status = 'requested'",
             name: :task_spec_review_requests_pending_index
           )

    create index(:task_spec_review_requests, [:reviewer_id], where: "status = 'requested'")

    create constraint(:task_spec_review_requests, :task_spec_review_requests_status_check,
             check: "status IN ('requested','submitted','cancelled','lapsed')"
           )

    create constraint(:task_spec_review_requests, :task_spec_review_requests_close_reason_check,
             check:
               "(status = 'cancelled') = (close_reason IS NOT NULL) AND " <>
                 "(close_reason IS NULL OR close_reason IN ('superseded','withdrawn','abandoned'))"
           )

    create constraint(:task_spec_review_requests, :task_spec_review_requests_note_length,
             check: "octet_length(note) <= 8192"
           )

    create table(:task_spec_issues) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :spec_id,
          references(:task_specs, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false

      add :review_id,
          references(:task_spec_reviews,
            with: [workspace_id: :workspace_id],
            on_delete: :delete_all
          ),
          null: false

      add :number, :integer, null: false
      add :severity, :text, null: false
      add :file, :text
      add :line, :integer
      add :anchor, :text
      add :body, :text, null: false
      add :suggestion, :text
      add :resolution, :text, null: false, default: "open"
      add :note_seq, :integer, null: false, default: 0
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:task_spec_issues, [:workspace_id, :id])
    create unique_index(:task_spec_issues, [:review_id, :number])
    create index(:task_spec_issues, [:spec_id, :resolution])

    create constraint(:task_spec_issues, :task_spec_issues_severity_check,
             check: "severity IN ('P1','P2','P3')"
           )

    create constraint(:task_spec_issues, :task_spec_issues_resolution_check,
             check:
               "resolution IN ('open','accepted','disputed','withdrawn','upheld','dismissed')"
           )

    create constraint(:task_spec_issues, :task_spec_issues_length,
             check:
               "octet_length(body) <= 8192 AND octet_length(suggestion) <= 8192 AND " <>
                 "octet_length(anchor) <= 200"
           )

    create table(:task_spec_issue_notes) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :issue_id,
          references(:task_spec_issues,
            with: [workspace_id: :workspace_id],
            on_delete: :delete_all
          ),
          null: false

      add :number, :integer, null: false
      add :author_id, references(:actors, with: [workspace_id: :workspace_id]), null: false

      add :source_run_id,
          references(:runs,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:source_run_id]}
          )

      add :kind, :text, null: false
      add :resolution, :text
      add :fixed_in_version, :integer
      add :body, :text, null: false, default: ""
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:task_spec_issue_notes, [:issue_id, :number])

    create constraint(:task_spec_issue_notes, :task_spec_issue_notes_kind_check,
             check: "kind IN ('reply','withdraw','ruling','comment')"
           )

    create constraint(:task_spec_issue_notes, :task_spec_issue_notes_resolution_check,
             check:
               "(kind = 'comment' AND resolution IS NULL) OR " <>
                 "(kind = 'reply' AND resolution IN ('accepted','disputed')) OR " <>
                 "(kind = 'withdraw' AND resolution = 'withdrawn') OR " <>
                 "(kind = 'ruling' AND resolution IN ('upheld','dismissed'))"
           )

    create constraint(:task_spec_issue_notes, :task_spec_issue_notes_body_length,
             check: "octet_length(body) <= 8192"
           )

    create table(:task_spec_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :spec_id,
          references(:task_specs, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false

      add :number, :integer, null: false
      add :actor_id, references(:actors, with: [workspace_id: :workspace_id]), null: false

      add :source_run_id,
          references(:runs,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:source_run_id]}
          )

      add :action, :text, null: false
      add :version, :integer
      add :data, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:task_spec_events, [:spec_id, :number])

    create constraint(:task_spec_events, :task_spec_events_data_length,
             check: "octet_length(data::text) <= 20480"
           )

    alter table(:projects) do
      add :spec_finalize, :text, null: false, default: "approval"
    end

    create constraint(:projects, :projects_spec_finalize_check,
             check: "spec_finalize IN ('approval','leader')"
           )

    alter table(:squads) do
      add :spec_finalize, :text
    end

    create constraint(:squads, :squads_spec_finalize_check,
             check: "spec_finalize IS NULL OR spec_finalize IN ('approval','leader')"
           )
  end

  def down do
    drop constraint(:squads, :squads_spec_finalize_check)

    alter table(:squads) do
      remove :spec_finalize
    end

    drop constraint(:projects, :projects_spec_finalize_check)

    alter table(:projects) do
      remove :spec_finalize
    end

    drop table(:task_spec_events)
    drop table(:task_spec_issue_notes)
    drop table(:task_spec_issues)
    drop table(:task_spec_review_requests)
    drop table(:task_spec_reviews)
    drop table(:task_spec_files)
    drop table(:task_spec_versions)
    drop table(:task_spec_blobs)
    drop table(:task_specs)
  end
end
