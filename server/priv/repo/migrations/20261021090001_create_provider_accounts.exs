defmodule Helmsman.Repo.Migrations.CreateProviderAccounts do
  use Ecto.Migration

  # `add-provider-accounts` decision 2: provider accounts belong to a user,
  # not to a workspace. Ownership is checked in the write transactions.
  def change do
    create table(:provider_accounts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :citext, null: false
      add :cli, :text, null: false
      add :base_url, :text, null: false
      add :api_key, :binary, null: false
      add :models, :jsonb, null: false, default: "{}"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:provider_accounts, [:user_id, :name])

    create constraint(:provider_accounts, :provider_accounts_cli_check,
             check: "cli IN ('claude','codex')"
           )

    alter table(:agent_profiles) do
      add :provider_account_id, references(:provider_accounts, on_delete: :restrict)
    end

    create index(:agent_profiles, [:provider_account_id])

    alter table(:runs) do
      add :provider_account_id, references(:provider_accounts, on_delete: :nilify_all)
    end

    create index(:runs, [:provider_account_id])
  end
end
