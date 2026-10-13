defmodule Helmsman.Repo.Migrations.CreateSavedFilters do
  use Ecto.Migration

  def change do
    create table(:saved_filters) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :name, :citext, null: false
      add :bql, :text, null: false
      add :visibility, :text, null: false, default: "private"
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:saved_filters, [:workspace_id, :owner_id, :name])
    create unique_index(:saved_filters, [:workspace_id, :id])

    create constraint(:saved_filters, :saved_filters_name_length,
             check: "char_length(name) BETWEEN 1 AND 80"
           )

    create constraint(:saved_filters, :saved_filters_bql_length,
             check: "char_length(bql) <= 2000"
           )

    create constraint(:saved_filters, :saved_filters_visibility_check,
             check: "visibility IN ('private', 'workspace')"
           )
  end
end
