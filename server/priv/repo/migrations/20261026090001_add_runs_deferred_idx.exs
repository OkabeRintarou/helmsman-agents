defmodule Helmsman.Repo.Migrations.AddRunsDeferredIdx do
  use Ecto.Migration

  # `add-dependency-dispatch` decision 1: the dependency sweep reads the
  # deferred runs by `(updated_at, id)`.
  def change do
    create index(:runs, [:updated_at, :id],
             name: :runs_deferred_idx,
             where: "status = 'deferred'"
           )
  end
end
