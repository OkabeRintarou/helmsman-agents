defmodule Helmsman.Repo.Migrations.CreateAgentExecutionTables do
  use Ecto.Migration

  def up do
    create table(:daemons) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :machine_id, :text, null: false
      add :name, :text, null: false
      add :os, :text
      add :arch, :text
      add :version, :text
      add :protocol_version, :integer
      add :max_concurrency, :integer, null: false, default: 4
      add :token_hash, :binary, null: false
      add :token_issued_at, :utc_datetime
      add :previous_token_hash, :binary
      add :previous_token_expires_at, :utc_datetime
      add :auth_epoch, :integer, null: false, default: 1
      add :last_seen_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:daemons, [:user_id, :machine_id])
    create unique_index(:daemons, [:token_hash])

    create unique_index(:daemons, [:previous_token_hash],
             where: "previous_token_hash IS NOT NULL"
           )

    create constraint(:daemons, :daemons_name_length, check: "char_length(name) BETWEEN 1 AND 64")

    create constraint(:daemons, :daemons_concurrency_check,
             check: "max_concurrency BETWEEN 1 AND 32"
           )

    create table(:daemon_workspaces, primary_key: false) do
      add :daemon_id, references(:daemons, on_delete: :delete_all), primary_key: true
      add :workspace_id, references(:workspaces, on_delete: :delete_all), primary_key: true
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:daemon_workspaces, [:workspace_id])

    create table(:device_codes) do
      add :device_code_hash, :binary, null: false
      add :user_code, :text, null: false
      add :machine, :map, null: false
      add :protocol_version, :integer, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :workspace_ids, {:array, :bigint}, null: false, default: []
      add :status, :text, null: false, default: "pending"
      add :interval, :integer, null: false, default: 5
      add :last_polled_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:device_codes, [:device_code_hash])

    create unique_index(:device_codes, [:user_code],
             name: :device_codes_active_user_code_index,
             where: "status IN ('pending','approved')"
           )

    create constraint(:device_codes, :device_codes_status_check,
             check: "status IN ('pending','approved','denied','used','expired')"
           )

    create table(:runtimes) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :daemon_id, references(:daemons, on_delete: :delete_all), null: false
      add :provider, :text, null: false
      add :cli_version, :text
      add :models, {:array, :text}, null: false, default: []
      add :efforts, {:array, :text}, null: false, default: []
      add :status, :text, null: false, default: "offline"
      add :unavailable_reason, :text
      add :disabled_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:runtimes, [:workspace_id, :daemon_id, :provider])
    create unique_index(:runtimes, [:workspace_id, :id])

    create constraint(:runtimes, :runtimes_provider_check,
             check: "provider IN ('claude','codex','copilot','cursor')"
           )

    create constraint(:runtimes, :runtimes_status_check, check: "status IN ('online','offline')")

    create table(:agent_profiles) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :actor_id, :bigint, null: false
      add :provider, :text, null: false
      add :runtime_id, :bigint
      add :model, :text
      add :effort, :text
      add :instructions, :text, null: false, default: ""
      add :description, :text, null: false, default: ""
      add :access, :text, null: false, default: "owner_only"
      add :access_member_ids, {:array, :bigint}, null: false, default: []
      add :capabilities, {:array, :text}, null: false, default: []
      add :max_concurrency, :integer, null: false, default: 2
      add :timeout_minutes, :integer, null: false, default: 120
      add :idle_timeout_minutes, :integer, null: false, default: 20
      add :custom_args, {:array, :text}, null: false, default: []
      add :env, :binary
      add :extra_mcp_servers, :binary
      add :archived_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    execute "ALTER TABLE agent_profiles ADD CONSTRAINT agent_profiles_actor_workspace_fkey FOREIGN KEY (workspace_id, actor_id) REFERENCES actors(workspace_id, id) ON DELETE CASCADE"

    execute "ALTER TABLE agent_profiles ADD CONSTRAINT agent_profiles_runtime_workspace_fkey FOREIGN KEY (workspace_id, runtime_id) REFERENCES runtimes(workspace_id, id) MATCH SIMPLE"

    create unique_index(:agent_profiles, [:actor_id])
    create unique_index(:agent_profiles, [:workspace_id, :id])
    create index(:agent_profiles, [:runtime_id])

    for {name, check} <- [
          provider: "provider IN ('claude','codex','copilot','cursor')",
          access: "access IN ('owner_only','members','workspace')",
          capabilities: "capabilities <@ ARRAY['create_tasks']::text[]",
          instructions: "octet_length(instructions) <= 65536",
          description: "char_length(description) <= 1000",
          max_concurrency: "max_concurrency BETWEEN 1 AND 16",
          timeout_minutes: "timeout_minutes BETWEEN 1 AND 1200",
          idle_timeout_minutes:
            "idle_timeout_minutes BETWEEN 1 AND 240 AND idle_timeout_minutes <= timeout_minutes",
          custom_args: "cardinality(custom_args) <= 64"
        ] do
      create constraint(:agent_profiles, "agent_profiles_#{name}_check", check: check)
    end
  end

  def down do
    drop table(:agent_profiles)
    drop table(:runtimes)
    drop table(:device_codes)
    drop table(:daemon_workspaces)
    drop table(:daemons)
  end
end
