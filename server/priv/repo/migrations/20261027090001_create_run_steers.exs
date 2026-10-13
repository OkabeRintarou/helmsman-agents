defmodule Helmsman.Repo.Migrations.CreateRunSteers do
  use Ecto.Migration

  # `add-run-steering` decision 2: feedback pushed into a running run
  # (`sent_at`) and the daemon's receipt (`acked_at`). Replaces the
  # `steer_receipts` of designs/01 §2.
  def change do
    create table(:run_steers, primary_key: false) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false

      add :run_id,
          references(:runs, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false,
          primary_key: true

      add :feedback_id,
          references(:feedback, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false,
          primary_key: true

      add :sent_at, :utc_datetime_usec, null: false
      add :acked_at, :utc_datetime_usec
    end

    create index(:run_steers, [:feedback_id])
  end
end
