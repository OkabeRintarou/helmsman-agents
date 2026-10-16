defmodule Helmsman.Repo.Migrations.AddDesignConversationKinds do
  use Ecto.Migration

  # `add-edit-design-conversations` decisions 3, 4: conversation kinds and
  # slots (one `open` conversation per user, workspace and slot), the target
  # and baseline of edit conversations, and the changes a confirm applied.
  def up do
    execute(
      "ALTER TABLE agent_designs DROP CONSTRAINT agent_designs_kind_check, " <>
        "ADD CONSTRAINT agent_designs_kind_check " <>
        "CHECK (kind IN ('agent','squad','agent_edit','squad_edit'))"
    )

    execute("""
    ALTER TABLE agent_designs ADD COLUMN slot text GENERATED ALWAYS AS (
      CASE WHEN kind IN ('agent','squad') THEN 'create'
           WHEN kind IN ('agent_edit','squad_edit') THEN 'edit'
           ELSE kind END
    ) STORED NOT NULL
    """)

    alter table(:agent_designs) do
      add :target_actor_id, references(:actors, on_delete: :delete_all)
      add :baseline, :jsonb
      add :applied, :jsonb
    end

    create constraint(:agent_designs, :agent_designs_target_check,
             check:
               "(kind IN ('agent_edit','squad_edit')) = " <>
                 "(target_actor_id IS NOT NULL AND baseline IS NOT NULL)"
           )

    drop index(:agent_designs, [:workspace_id, :user_id], name: :agent_designs_one_open_index)

    create unique_index(:agent_designs, [:workspace_id, :user_id, :slot],
             where: "status = 'open'",
             name: :agent_designs_one_open_per_slot_index
           )

    create index(:agent_designs, [:target_actor_id], where: "target_actor_id IS NOT NULL")
  end

  # Development rollback only: edit conversations (and their messages) go.
  def down do
    execute("DELETE FROM agent_designs WHERE kind IN ('agent_edit','squad_edit')")

    drop index(:agent_designs, [:target_actor_id], where: "target_actor_id IS NOT NULL")

    drop index(:agent_designs, [:workspace_id, :user_id, :slot],
           name: :agent_designs_one_open_per_slot_index
         )

    create unique_index(:agent_designs, [:workspace_id, :user_id],
             where: "status = 'open'",
             name: :agent_designs_one_open_index
           )

    drop constraint(:agent_designs, :agent_designs_target_check)

    alter table(:agent_designs) do
      remove :applied
      remove :baseline
      remove :target_actor_id
      remove :slot
    end

    execute(
      "ALTER TABLE agent_designs DROP CONSTRAINT agent_designs_kind_check, " <>
        "ADD CONSTRAINT agent_designs_kind_check CHECK (kind IN ('agent','squad'))"
    )
  end
end
