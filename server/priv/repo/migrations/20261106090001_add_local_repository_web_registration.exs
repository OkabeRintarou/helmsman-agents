defmodule Helmsman.Repo.Migrations.AddLocalRepositoryWebRegistration do
  use Ecto.Migration

  # `add-local-repo-web-registration` D8 and D10: whether a daemon allows
  # registering local repositories from the web, and the audit trail of
  # those requests. Machine-side data: not exported with a workspace.
  def change do
    alter table(:daemons) do
      add :repo_registration, :boolean, null: false, default: false
    end

    create table(:local_repository_changes) do
      add :daemon_id, references(:daemons, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :action, :text, null: false
      add :name, :text, null: false
      add :root, :text
      add :path, :text
      add :workspace_ids, {:array, :bigint}, null: false, default: []
      add :request_id, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :error, :text
      add :message, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
    end

    create unique_index(:local_repository_changes, [:request_id])
    create index(:local_repository_changes, [:daemon_id, :inserted_at])
    create index(:local_repository_changes, [:workspace_id, :inserted_at])
    create index(:local_repository_changes, [:workspace_ids], using: :gin)

    create constraint(:local_repository_changes, :local_repository_changes_action_check,
             check: "action IN ('register','remove')"
           )

    create constraint(:local_repository_changes, :local_repository_changes_status_check,
             check: "status IN ('pending','succeeded','failed')"
           )

    create constraint(:local_repository_changes, :local_repository_changes_location_check,
             check:
               "(action = 'register' AND root IS NOT NULL AND path IS NOT NULL) OR " <>
                 "(action <> 'register' AND root IS NULL AND path IS NULL)"
           )

    create constraint(:local_repository_changes, :local_repository_changes_message_length,
             check: "message IS NULL OR octet_length(message) <= 1024"
           )
  end
end
