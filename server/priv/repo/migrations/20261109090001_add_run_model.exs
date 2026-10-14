defmodule Helmsman.Repo.Migrations.AddRunModel do
  use Ecto.Migration

  # `add-run-model` decision 1: the model the claim sent to the daemon;
  # nil for the CLI's or the account's default and for unclaimed runs.
  def change do
    alter table(:runs) do
      add :model, :text
    end
  end
end
