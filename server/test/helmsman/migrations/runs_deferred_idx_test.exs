defmodule Helmsman.Migrations.RunsDeferredIdxTest do
  # add-dependency-dispatch 1.1: the sweep reads deferred runs by
  # `(updated_at, id)` through the partial index `runs_deferred_idx`.
  use Helmsman.DataCase, async: true

  test "the index exists, partial on deferred runs" do
    %{rows: [[definition]]} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = 'runs_deferred_idx'")

    assert definition =~ "(updated_at, id)"
    assert definition =~ "WHERE (status = 'deferred'::text)"
  end

  test "the sweep's order uses it" do
    # A table of a test database is tiny: the planner must not prefer a
    # sequential scan and a sort only because of that.
    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL enable_sort = off")

    %{rows: rows} =
      Repo.query!(
        "EXPLAIN SELECT id FROM runs WHERE status = 'deferred' ORDER BY updated_at, id LIMIT 500"
      )

    assert rows |> List.flatten() |> Enum.join("\n") =~ "runs_deferred_idx"
  end
end
