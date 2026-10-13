defmodule Helmsman.Repo.Migrations.AddProviderAccountHeaders do
  use Ecto.Migration

  def change do
    alter table(:provider_accounts) do
      add :header_names, {:array, :text}, null: false, default: []
      add :headers, :binary
    end
  end
end
