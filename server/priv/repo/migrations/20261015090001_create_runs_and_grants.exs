defmodule Helmsman.Repo.Migrations.CreateRunsAndGrants do
  use Ecto.Migration

  # designs/13 §4: every status a run can take; later changes do not touch
  # the constraint.
  @statuses ~w(deferred queued claimed running cancelling succeeded failed cancelled)

  # designs/13 §5.
  @failure_reasons ~w(runtime_offline daemon_restart lease_expired timeout stalled
    provider_network provider_rate_limit provider_auth provider_quota cli_missing
    cli_version workspace_prepare push_conflict push_failed context_overflow obsolete
    unauthorized cli_error unknown)

  def change do
    create table(:runs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :agent_id, references(:actors, with: [workspace_id: :workspace_id]), null: false

      add :runtime_id, references(:runtimes, with: [workspace_id: :workspace_id]), null: false

      # MATCH SIMPLE: only checked when task_id is set.
      add :task_id, references(:tasks, with: [workspace_id: :workspace_id])
      add :lane, :text, null: false
      add :status, :text, null: false
      add :triggers, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :root_initiator_user_id, references(:users), null: false
      add :causal_agent_ids, {:array, :bigint}, null: false
      add :capabilities, {:array, :text}, null: false
      add :priority, :smallint, null: false
      add :failure_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runs, [:workspace_id, :id])

    # `add-squads` rebuilds it with `coalesce(squad_id, 0)`.
    create unique_index(:runs, [:task_id, :agent_id, :lane],
             name: :runs_pending_index,
             where: "status IN ('deferred','queued')"
           )

    create index(:runs, [:runtime_id, :status, "priority DESC", :inserted_at, :id])
    create index(:runs, [:task_id, "inserted_at DESC"])
    create index(:runs, [:agent_id, :status])

    create index(:runs, [:root_initiator_user_id],
             where: "status IN ('deferred','queued')",
             name: :runs_pending_initiator_index
           )

    create constraint(:runs, :runs_lane_check, check: "lane IN ('work','reply')")
    create constraint(:runs, :runs_status_check, check: "status IN (#{list(@statuses)})")

    create constraint(:runs, :runs_failure_reason_check,
             check: "failure_reason IS NULL OR failure_reason IN (#{list(@failure_reasons)})"
           )

    create constraint(:runs, :runs_triggers_check, check: "jsonb_typeof(triggers) = 'array'")

    create constraint(:runs, :runs_capabilities_check,
             check: "capabilities <@ ARRAY['read','write_task','create_tasks','delegate']::text[]"
           )

    create constraint(:runs, :runs_priority_check, check: "priority BETWEEN 1 AND 3")

    create table(:run_tokens) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:run_tokens, [:run_id])
    create unique_index(:run_tokens, [:token_hash])

    create table(:task_grants) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :task_id, references(:tasks, with: [workspace_id: :workspace_id]), null: false

      add :agent_id, references(:actors, with: [workspace_id: :workspace_id]), null: false
      add :kind, :text, null: false
      add :root_initiator_user_id, references(:users), null: false
      add :causal_agent_ids, {:array, :bigint}, null: false

      add :granted_by_id, references(:actors, with: [workspace_id: :workspace_id]), null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:task_grants, [:task_id, :agent_id, :kind])
    # `add-squads` adds `delegate`.
    create constraint(:task_grants, :task_grants_kind_check, check: "kind IN ('assign')")

    # MATCH SIMPLE: only checked when source_run_id is set.
    alter table(:task_events) do
      add :source_run_id, references(:runs, with: [workspace_id: :workspace_id])
    end

    alter table(:feedback) do
      add :source_run_id, references(:runs, with: [workspace_id: :workspace_id])
    end
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
