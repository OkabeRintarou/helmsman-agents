defmodule Helmsman.Repo.Migrations.AddIdentityColumnsToActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add :project_key, :text
      add :worktree, :text
      add :last_seen_at, :utc_datetime_usec
    end
  end
end
