defmodule Helmsman.Repo.Migrations.CreateUserMcpServers do
  use Ecto.Migration

  def change do
    create table(:user_mcp_servers) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :citext, null: false
      add :config, :binary, null: false
      add :type, :text, null: false
      add :lock_version, :integer, default: 1, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_mcp_servers, [:user_id, :name])

    create table(:agent_mcp_server_refs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :agent_actor_id, references(:agent_profiles, column: :actor_id, on_delete: :delete_all),
        null: false

      add :server_id, references(:user_mcp_servers, on_delete: :delete_all), null: false
      add :position, :integer, null: false
    end

    create unique_index(:agent_mcp_server_refs, [:agent_actor_id, :server_id])
    create index(:agent_mcp_server_refs, [:server_id])
  end
end
