defmodule Helmsman.Repo.Migrations.CreateAutopilots do
  use Ecto.Migration

  # `add-autopilots` decision 1: autopilots and one row per trigger
  # (`autopilot_runs`) with the execution configuration it froze.
  def up do
    create table(:autopilots) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :name, :citext, null: false

      add :agent_id, references(:actors, with: [workspace_id: :workspace_id]), null: false

      add :project_id, references(:projects, with: [workspace_id: :workspace_id])
      add :mode, :text, null: false
      add :title_template, :text
      add :instructions, :text, null: false
      add :create_tasks, :boolean, null: false, default: false
      add :cron, :text
      add :timezone, :text, null: false, default: "UTC"
      add :overlap, :text, null: false, default: "skip"
      add :enabled, :boolean, null: false, default: true
      add :next_run_at, :utc_datetime_usec
      add :webhook_token_hash, :binary
      add :initiator_user_id, references(:users, on_delete: :nilify_all)
      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      add :disabled_reason, :text
      add :consecutive_failures, :integer, null: false, default: 0
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:autopilots, [:workspace_id, :id])
    create unique_index(:autopilots, [:workspace_id, :name])
    create index(:autopilots, [:initiator_user_id])
    create index(:autopilots, [:agent_id])

    create constraint(:autopilots, :autopilots_mode_check,
             check: "mode IN ('create_task','run_only')"
           )

    create constraint(:autopilots, :autopilots_overlap_check,
             check: "overlap IN ('skip','queue')"
           )

    create constraint(:autopilots, :autopilots_create_task_check,
             check:
               "mode <> 'create_task' OR (project_id IS NOT NULL AND title_template IS NOT NULL)"
           )

    create constraint(:autopilots, :autopilots_name_length,
             check: "char_length(name::text) BETWEEN 1 AND 80"
           )

    create constraint(:autopilots, :autopilots_title_template_length,
             check: "char_length(title_template) <= 200"
           )

    create constraint(:autopilots, :autopilots_instructions_length,
             check: "octet_length(instructions) <= 16384"
           )

    create constraint(:autopilots, :autopilots_schedule_check,
             check: "enabled OR next_run_at IS NULL"
           )

    create constraint(:autopilots, :autopilots_disabled_reason_check,
             check:
               "disabled_reason IS NULL OR disabled_reason IN ('manual','consecutive_failures'," <>
                 "'unauthorized','initiator_left','agent_archived','project_archived')"
           )

    create table(:autopilot_runs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :autopilot_id,
          references(:autopilots, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false

      add :source, :text, null: false
      add :scheduled_for, :utc_datetime_usec
      add :delivery_id, :text
      add :initiator_user_id, references(:users, on_delete: :nilify_all)
      add :note, :text
      add :payload, :jsonb
      add :config, :jsonb, null: false

      # Only the task / run column is cleared when the task or run goes (an
      # import that replaces the workspace's tasks, `add-export-import`).
      add :task_id,
          references(:tasks,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:task_id]}
          )

      add :run_id,
          references(:runs, with: [workspace_id: :workspace_id], on_delete: {:nilify, [:run_id]})

      add :status, :text, null: false
      add :reason, :text
      add :result, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:autopilot_runs, [:autopilot_id],
             where: "status = 'started'",
             name: :autopilot_runs_one_started_index
           )

    create unique_index(:autopilot_runs, [:autopilot_id],
             where: "status = 'pending'",
             name: :autopilot_runs_one_pending_index
           )

    create unique_index(:autopilot_runs, [:autopilot_id, :delivery_id])
    create unique_index(:autopilot_runs, [:autopilot_id, :scheduled_for])
    create unique_index(:autopilot_runs, [:run_id], where: "run_id IS NOT NULL")
    create index(:autopilot_runs, [:task_id], where: "status = 'started'")
    create index(:autopilot_runs, [:autopilot_id, "id DESC"])
    create index(:autopilot_runs, [:initiator_user_id])

    create constraint(:autopilot_runs, :autopilot_runs_source_check,
             check: "source IN ('schedule','manual','webhook')"
           )

    create constraint(:autopilot_runs, :autopilot_runs_status_check,
             check: "status IN ('pending','skipped','started','succeeded','failed','cancelled')"
           )

    create constraint(:autopilot_runs, :autopilot_runs_delivery_id_length,
             check: "octet_length(delivery_id) <= 200"
           )

    create constraint(:autopilot_runs, :autopilot_runs_note_length,
             check: "octet_length(note) <= 4096"
           )

    create constraint(:autopilot_runs, :autopilot_runs_result_length,
             check: "octet_length(result) <= 4096"
           )
  end

  # Development rollback only: run-only runs still waiting to be claimed
  # are cancelled first (their autopilot rows go with the tables).
  def down do
    execute("""
    UPDATE runs SET status = 'cancelled', failure_reason = 'obsolete',
      finished_at = now(), updated_at = now()
    WHERE status IN ('deferred','queued') AND task_id IS NULL
      AND triggers @> '[{"kind": "autopilot"}]'::jsonb
    """)

    drop table(:autopilot_runs)
    drop table(:autopilots)
  end
end
