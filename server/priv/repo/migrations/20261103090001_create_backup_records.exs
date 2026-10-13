defmodule Helmsman.Repo.Migrations.CreateBackupRecords do
  use Ecto.Migration

  def change do
    create table(:exports) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :status, :text, null: false, default: "queued"
      add :file, :text
      add :size, :bigint
      add :sha256, :text
      add :counts, :map, null: false, default: %{}
      add :error, :text
      add :expires_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:exports, [:workspace_id],
             where: "status IN ('queued', 'running')",
             name: :exports_active
           )

    create constraint(:exports, :exports_status,
             check: "status IN ('queued','running','succeeded','failed')"
           )

    create constraint(:exports, :exports_file_length, check: "char_length(file) <= 255")

    create constraint(:exports, :exports_sha256_length,
             check: "sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:exports, :exports_size, check: "size IS NULL OR size >= 0")

    create table(:imports) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :mode, :text, null: false, default: "merge"
      add :dry_run, :boolean, null: false, default: false
      add :source, :text, null: false, default: "helmsman"
      add :file_sha256, :text
      add :file_name, :text
      add :status, :text, null: false, default: "queued"
      add :report, :map, null: false, default: %{}
      add :errors, {:array, :map}, null: false, default: []
      add :upload, :text
      add :options, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:imports, [:workspace_id],
             where: "status IN ('queued', 'running')",
             name: :imports_active
           )

    create constraint(:imports, :imports_status,
             check: "status IN ('queued','running','succeeded','failed')"
           )

    create constraint(:imports, :imports_mode, check: "mode IN ('merge','replace')")
    create constraint(:imports, :imports_source, check: "source IN ('helmsman','bosun')")

    create constraint(:imports, :imports_file_name_length,
             check: "char_length(file_name) <= 255 AND char_length(upload) <= 255"
           )

    create constraint(:imports, :imports_sha256_length,
             check: "file_sha256 IS NULL OR file_sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:imports, :imports_errors_length, check: "cardinality(errors) <= 100")

    create table(:actor_claims) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :actor_id,
          references(:actors, with: [workspace_id: :workspace_id], on_delete: :delete_all),
          null: false

      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :status, :text, null: false, default: "pending"
      add :decided_by_id, references(:users)
      add :decided_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:actor_claims, [:actor_id, :user_id],
             where: "status = 'pending'",
             name: :actor_claims_pending
           )

    create constraint(:actor_claims, :actor_claims_status,
             check: "status IN ('pending','approved','rejected','cancelled')"
           )
  end
end
