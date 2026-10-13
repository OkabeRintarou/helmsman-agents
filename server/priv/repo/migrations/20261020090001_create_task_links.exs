defmodule Helmsman.Repo.Migrations.CreateTaskLinks do
  use Ecto.Migration

  def change do
    # Directed links between two tasks of one workspace (designs/07 §1):
    # `replaces` (from takes over to) and `depends_on` (from waits for to).
    create table(:task_links, primary_key: false) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false

      add :from_task_id,
          references(:tasks, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false,
          primary_key: true

      add :to_task_id,
          references(:tasks, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false,
          primary_key: true

      add :type, :text, null: false, primary_key: true

      add :actor_id,
          references(:actors, with: [workspace_id: :workspace_id], on_delete: :restrict),
          null: false

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:task_links, [:to_task_id, :type])

    create constraint(:task_links, :task_links_type_check,
             check: "type IN ('replaces', 'depends_on')"
           )

    create constraint(:task_links, :task_links_not_self, check: "from_task_id <> to_task_id")
  end
end
