defmodule Helmsman.Repo.Migrations.CreateAvatars do
  use Ecto.Migration

  # `add-actor-avatars` decisions 3 and 19: avatars of users (shown on
  # their human identities) and of agent and squad identities, and the
  # icon key of a provider account.
  def change do
    create table(:avatars) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :workspace_id, references(:workspaces, on_delete: :delete_all)

      add :actor_id,
          references(:actors, with: [workspace_id: :workspace_id], on_delete: :delete_all)

      add :content_type, :text, null: false
      add :data, :binary, null: false
      add :key, :text, null: false
      add :byte_size, :integer, null: false
      add :edge, :integer, null: false
      add :updated_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:avatars, [:user_id])
    create unique_index(:avatars, [:actor_id])
    create index(:avatars, [:workspace_id, :key])
    create index(:avatars, [:key], where: "user_id IS NOT NULL", name: :avatars_user_key_index)

    create constraint(:avatars, :avatars_one_owner,
             check: "(user_id IS NULL) <> (actor_id IS NULL)"
           )

    create constraint(:avatars, :avatars_actor_workspace,
             check: "(workspace_id IS NULL) = (actor_id IS NULL)"
           )

    create constraint(:avatars, :avatars_content_type,
             check: "content_type IN ('image/png', 'image/jpeg', 'image/webp')"
           )

    create constraint(:avatars, :avatars_byte_size,
             check: "byte_size BETWEEN 1 AND 262144 AND byte_size = octet_length(data)"
           )

    create constraint(:avatars, :avatars_edge, check: "edge BETWEEN 32 AND 1024")
    create constraint(:avatars, :avatars_key_format, check: "key ~ '^[0-9a-f]{32}$'")

    alter table(:provider_accounts) do
      add :icon, :text
    end

    create constraint(:provider_accounts, :provider_accounts_icon_format,
             check: "icon ~ '^[a-z0-9]{1,32}$'"
           )
  end
end
