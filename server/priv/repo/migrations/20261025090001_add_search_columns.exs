defmodule Helmsman.Repo.Migrations.AddSearchColumns do
  use Ecto.Migration

  # `add-fulltext-search` decision 2: the search columns are written by the
  # application (`Helmsman.Search.Document`) in the transaction of every
  # write. Existing rows stay empty until `mix helmsman.reindex` runs.
  def change do
    alter table(:tasks) do
      add :search, :tsvector
    end

    alter table(:feedback) do
      add :search, :tsvector
    end

    create index(:tasks, [:search], using: :gin, name: :tasks_search_idx)
    create index(:feedback, [:search], using: :gin, name: :feedback_search_idx)
  end
end
