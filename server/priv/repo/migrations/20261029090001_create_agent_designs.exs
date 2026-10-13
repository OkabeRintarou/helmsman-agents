defmodule Helmsman.Repo.Migrations.CreateAgentDesigns do
  use Ecto.Migration

  # `add-agent-conversation` decision 3: creation conversations and their
  # messages; decision 7: the `design` capability of design runs.
  def change do
    create table(:agent_designs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :helper_agent_id, references(:actors, on_delete: :delete_all), null: false
      add :kind, :text, null: false, default: "agent"
      add :status, :text, null: false, default: "open"
      add :draft, :jsonb, null: false, default: fragment("'{\"agents\": []}'::jsonb")
      add :draft_version, :integer, null: false, default: 0
      add :pending_edits, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :current_run_id, references(:runs, on_delete: :nilify_all)
      add :user_messages, :integer, null: false, default: 0
      add :created_actor_ids, {:array, :bigint}, null: false, default: []
      add :last_activity_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:agent_designs, :agent_designs_kind_check, check: "kind IN ('agent')")

    create constraint(:agent_designs, :agent_designs_status_check,
             check: "status IN ('open','confirmed','discarded','expired')"
           )

    create unique_index(:agent_designs, [:workspace_id, :user_id],
             where: "status = 'open'",
             name: :agent_designs_one_open_index
           )

    create unique_index(:agent_designs, [:current_run_id],
             where: "current_run_id IS NOT NULL",
             name: :agent_designs_current_run_index
           )

    create index(:agent_designs, [:status, :last_activity_at])
    create index(:agent_designs, [:closed_at])
    create index(:agent_designs, [:helper_agent_id])

    create table(:agent_design_messages) do
      add :design_id, references(:agent_designs, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :role, :text, null: false
      add :content, :text
      add :edits, :jsonb
      add :code, :text
      add :detail, :text
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create constraint(:agent_design_messages, :agent_design_messages_role_check,
             check: "role IN ('user','assistant','system')"
           )

    create unique_index(:agent_design_messages, [:design_id, :seq])

    create unique_index(:agent_design_messages, [:run_id],
             where: "role <> 'user'",
             name: :agent_design_messages_settled_run_index
           )

    create index(:agent_design_messages, [:run_id], where: "role = 'user'")

    execute(
      "ALTER TABLE runs DROP CONSTRAINT runs_capabilities_check, ADD CONSTRAINT " <>
        "runs_capabilities_check CHECK (capabilities <@ " <>
        "ARRAY['read','write_task','create_tasks','delegate','design']::text[])",
      "ALTER TABLE runs DROP CONSTRAINT runs_capabilities_check, ADD CONSTRAINT " <>
        "runs_capabilities_check CHECK (capabilities <@ " <>
        "ARRAY['read','write_task','create_tasks','delegate']::text[])"
    )
  end
end
