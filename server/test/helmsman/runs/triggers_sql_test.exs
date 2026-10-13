defmodule Helmsman.Runs.TriggersSqlTest do
  # add-dependency-dispatch 1.3: `dependency_gated_sql/1` is
  # `dependency_gated?/1` in SQL (the sweep and the release use it).
  use Helmsman.DataCase, async: true
  use ExUnitProperties

  import Helmsman.Runs.Triggers, only: [dependency_gated_sql: 1]

  alias Helmsman.Runs.Triggers

  @kinds ~w(assign reopen resubmit manual mention answer requested unblocked autopilot)

  defp entry do
    one_of([
      map(member_of(@kinds), &%{"kind" => &1}),
      map(boolean(), &%{"kind" => "retry", "auto" => &1})
    ])
  end

  property "SQL and Elixir agree" do
    check all triggers <- list_of(entry(), max_length: 4), max_runs: 200 do
      sql =
        Repo.one(
          from(x in fragment("SELECT ?::jsonb AS t", ^triggers),
            select: dependency_gated_sql(x.t)
          )
        )

      assert sql == Triggers.dependency_gated?(triggers)
    end
  end
end
