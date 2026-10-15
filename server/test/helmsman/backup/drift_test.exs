defmodule Helmsman.Backup.DriftTest do
  use Helmsman.DataCase, async: true
  alias Helmsman.Actors.Claims
  alias Helmsman.Backup.Import.Replace

  defp foreign_keys do
    Repo.query!(
      "SELECT source.relname, a.attname, target.relname, c.confdeltype::text FROM pg_constraint c JOIN pg_class source ON source.oid=c.conrelid JOIN pg_class target ON target.oid=c.confrelid JOIN LATERAL unnest(c.conkey,c.confkey) AS cols(src,dst) ON true JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=cols.src JOIN pg_attribute b ON b.attrelid=c.confrelid AND b.attnum=cols.dst WHERE c.contype='f' AND b.attname='id'"
    ).rows
  end

  test "all foreign keys to replaced objects have an explicit deletion strategy" do
    actual =
      foreign_keys()
      |> Enum.filter(fn [_, _, target, _] -> target in Replace.deletion_tables() end)
      |> MapSet.new(fn [table, col, _, _] -> {table, col} end)

    declared =
      MapSet.new(
        Replace.deleted_columns() ++ Replace.null_columns() ++ Replace.database_null_columns()
      )

    assert actual == declared

    for {table, col} <- Replace.database_null_columns() do
      assert [table, col, "runs", "n"] in foreign_keys()
    end
  end

  test "claim reference list covers every actor foreign key" do
    actual =
      foreign_keys()
      |> Enum.filter(fn [_, _, target, _] -> target == "actors" end)
      |> MapSet.new(fn [table, col, _, _] -> {table, col} end)

    assert actual == MapSet.new(Claims.foreign_columns())
  end

  test "actor foreign columns in unique keys have a conflict rule or are non-human" do
    indexes =
      Repo.query!(
        "SELECT t.relname, a.attname FROM pg_index i JOIN pg_class t ON t.oid=i.indrelid JOIN LATERAL unnest(i.indkey) col(attnum) ON true JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=col.attnum WHERE i.indisunique"
      ).rows

    columns = MapSet.new(Claims.foreign_columns())

    actual =
      indexes
      |> Enum.map(&List.to_tuple/1)
      |> Enum.filter(&MapSet.member?(columns, &1))
      |> MapSet.new()

    allowed =
      MapSet.new(
        Claims.agent_only() ++
          [
            {"squad_members", "actor_id"},
            {"actor_claims", "actor_id"},
            # The pending-request index: `Claims.merge_review_requests/3`.
            {"task_spec_review_requests", "reviewer_id"}
          ]
      )

    assert MapSet.subset?(actual, allowed)
  end
end
