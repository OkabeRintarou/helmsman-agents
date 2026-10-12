defmodule Helmsman.Repo.Migrations.AddContinuationTriggers do
  use Ecto.Migration

  # add-continuation-triggers decision 2. Before rolling back, delete the
  # `requested` grants (the narrowed constraint rejects them).
  def change do
    alter table(:agent_profiles) do
      add :wake_on_requested, :boolean, null: false, default: true
    end

    execute(kind_check("kind IN ('assign','requested')"), kind_check("kind IN ('assign')"))

    alter table(:feedback) do
      add :dispatch, :jsonb, null: false, default: fragment("'[]'::jsonb")
    end

    create constraint(:feedback, :feedback_dispatch_check,
             check: "jsonb_typeof(dispatch) = 'array'"
           )

    alter table(:task_events) do
      add :auto_reason, :text
    end

    create constraint(:task_events, :task_events_auto_reason_check,
             check:
               "auto_reason IS NULL OR (auto AND auto_reason IN ('ci_failed','merge_conflict'))"
           )
  end

  # `add-squads` adds `delegate`.
  defp kind_check(check) do
    "ALTER TABLE task_grants DROP CONSTRAINT task_grants_kind_check, " <>
      "ADD CONSTRAINT task_grants_kind_check CHECK (#{check})"
  end
end
