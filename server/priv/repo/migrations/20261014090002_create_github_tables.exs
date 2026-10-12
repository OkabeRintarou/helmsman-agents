defmodule Helmsman.Repo.Migrations.CreateGithubTables do
  use Ecto.Migration

  def change do
    create table(:github_apps) do
      add :app_id, :bigint, null: false
      add :slug, :text, null: false
      add :name, :text, null: false
      add :html_url, :text, null: false
      add :owner_login, :text
      add :client_id, :text, null: false
      add :client_secret, :bytea, null: false
      add :private_key, :bytea, null: false
      add :webhook_secret, :bytea, null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    # At most one App per instance.
    execute "CREATE UNIQUE INDEX github_apps_single_row ON github_apps ((true))",
            "DROP INDEX github_apps_single_row"

    create table(:github_installations) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false
      add :installation_id, :bigint, null: false
      add :account_login, :text, null: false
      add :account_type, :text, null: false
      add :suspended_at, :utc_datetime
      add :disconnected_at, :utc_datetime
      add :fetched_at, :utc_datetime_usec, null: false
      add :repos_fetched_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create unique_index(:github_installations, [:installation_id])
    create unique_index(:github_installations, [:workspace_id, :id])

    # A workspace has at most one connected installation.
    create unique_index(:github_installations, [:workspace_id],
             where: "disconnected_at IS NULL",
             name: :github_installations_one_connected_index
           )

    create table(:repositories) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false

      add :installation_id,
          references(:github_installations,
            with: [workspace_id: :workspace_id],
            on_delete: :restrict
          ),
          null: false

      add :github_id, :bigint, null: false
      add :owner, :text, null: false
      add :name, :text, null: false
      add :default_branch, :text, null: false
      add :archived, :boolean, null: false, default: false
      add :private, :boolean, null: false, default: false
      add :removed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:repositories, [:workspace_id, :github_id])
    create unique_index(:repositories, [:workspace_id, :id])
    create index(:repositories, [:installation_id])

    create table(:github_deliveries, primary_key: false) do
      add :delivery_id, :text, primary_key: true
      add :event, :text, null: false
      add :received_at, :utc_datetime, null: false
    end

    create index(:github_deliveries, [:received_at])

    alter table(:projects) do
      add :repository_id,
          references(:repositories, with: [workspace_id: :workspace_id], on_delete: :restrict)

      add :base_branch, :text
      add :merge_policy, :text, null: false, default: "on_verified"
      add :merge_method, :text, null: false, default: "squash"
      add :require_ci, :boolean, null: false, default: true
      add :delete_branch_after_merge, :boolean, null: false, default: true
    end

    create index(:projects, [:repository_id])

    create constraint(:projects, :projects_merge_policy_check,
             check: "merge_policy IN ('on_verified', 'on_verified_human', 'manual')"
           )

    create constraint(:projects, :projects_merge_method_check,
             check: "merge_method IN ('squash', 'merge', 'rebase')"
           )

    create constraint(:projects, :projects_base_branch_length,
             check: "base_branch IS NULL OR char_length(base_branch) BETWEEN 1 AND 255"
           )
  end
end
