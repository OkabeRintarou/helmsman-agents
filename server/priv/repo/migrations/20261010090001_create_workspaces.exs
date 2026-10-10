defmodule Helmsman.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces) do
      add :slug, :citext, null: false
      add :name, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspaces, [:slug])

    # citext overrides `~` to be case-insensitive; compare as text.
    create constraint(:workspaces, :workspaces_slug_format,
             check: "slug::text ~ '^[a-z0-9][a-z0-9-]{1,38}$'"
           )

    create constraint(:workspaces, :workspaces_name_length,
             check: "char_length(name) BETWEEN 1 AND 80"
           )
  end
end
