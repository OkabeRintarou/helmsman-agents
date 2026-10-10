defmodule Helmsman.Repo.Migrations.AddEvidenceToTaskEvents do
  use Ecto.Migration

  def change do
    # Existing rows are creation entries: no commits, no tests, not automatic.
    alter table(:task_events) do
      add :commits, {:array, :text}, null: false, default: []
      add :tests, :map
      add :auto, :boolean, null: false, default: false
    end

    # The database only guarantees "absent, or an object with a boolean
    # `passed`"; Helmsman.Tasks.Evidence checks `command` and `summary`.
    # A missing `passed` makes jsonb_typeof NULL, which CHECK would accept
    # without the COALESCE.
    create constraint(:task_events, :task_events_tests_check,
             check:
               "tests IS NULL OR (jsonb_typeof(tests) = 'object' AND " <>
                 "COALESCE(jsonb_typeof(tests -> 'passed') = 'boolean', false))"
           )
  end
end
