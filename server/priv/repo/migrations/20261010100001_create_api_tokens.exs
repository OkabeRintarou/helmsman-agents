defmodule Helmsman.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :name, :text, null: false
      add :token_hash, :binary, null: false
      add :prefix, :text, null: false
      add :scopes, {:array, :text}, null: false
      # MATCH SIMPLE: only checked when default_agent_id is set.
      add :default_agent_id,
          references(:actors, with: [workspace_id: :workspace_id], on_delete: :restrict)

      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
    create unique_index(:api_tokens, [:workspace_id, :id])
    create index(:api_tokens, [:workspace_id, :user_id])

    create constraint(:api_tokens, :api_tokens_scopes_check,
             check:
               "scopes <@ ARRAY['mcp', 'api:read', 'api:write']::text[] AND cardinality(scopes) > 0"
           )

    create constraint(:api_tokens, :api_tokens_name_length,
             check: "char_length(name) BETWEEN 1 AND 64"
           )
  end
end
