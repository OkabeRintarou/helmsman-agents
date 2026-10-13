defmodule Helmsman.BQL.BosunCompatTest do
  use Helmsman.DataCase, async: true
  import Helmsman.BQLFixtures
  alias Helmsman.{Filters, Tasks}

  setup do
    bql_fixture()
  end

  defp ids(scope, q, opts \\ []) do
    assert {:ok, result} = Tasks.query(scope, q, opts)
    Enum.map(result.tasks, & &1.id)
  end

  test "all legacy pre-link queries on the reconstructed dataset", ctx do
    for {q, expected} <- [
          {"kind = epic", ["OT-2"]},
          {"epic = ot-2", ["BQ-3"]},
          {"parent in (OT-2)", ["BQ-3"]},
          {"project = bq AND labels = Backend AND priority = high", ["BQ-1"]},
          {"labels in (backend)", ["BQ-1", "OT-1"]},
          {"project = BQ and status = new order by priority desc", ["BQ-1", "BQ-3"]},
          {"project = BQ and status = new order by priority asc", ["BQ-3", "BQ-1"]},
          {"status not in (new) and project = BQ", ["BQ-2"]},
          {"question = true", ["BQ-3"]},
          {"feedback ~ port", ["BQ-3"]},
          {"feedback_count >= 1", ["BQ-3"]},
          {"text ~ \"创建任务\"", ["BQ-1"]},
          {"reporter = coxswain", ["BQ-1"]},
          {"requester = coxswain", ["BQ-1"]},
          {"assignee = user", ["BQ-2"]},
          {"assignee ~ use", ["BQ-2"]},
          {"assignee is not empty order by assignee", ["BQ-2"]},
          {"project = BQ and labels is empty", ["BQ-3"]},
          {"title ~ docs", ["BQ-2"]},
          {"project = BQ and created >= -1h order by id desc", ["BQ-3", "BQ-2", "BQ-1"]},
          {"created < 2020-01-01", []},
          {"(labels = backend or labels = mcp) and not status = done", ["BQ-1", "OT-1"]},
          {"project = OT and status = new and kind = epic", ["OT-2"]}
        ] do
      actual = ids(ctx.scope, q)

      if String.contains?(q, "order by"),
        do: assert(actual == expected, q),
        else: assert(Enum.sort(actual) == Enum.sort(expected), q)
    end

    for {q, n} <- [
          {"epic is empty", 4},
          {"type = task", 4},
          {"assignee is empty", 4},
          {"created >= 2020-01-01T00:00", 5}
        ],
        do: assert(length(ids(ctx.scope, q)) == n)

    for q <- ["kind = story", "bogus = 1"],
        do: assert({:error, {:invalid_bql, _}} = Tasks.query(ctx.scope, q))

    assert {:ok, %{order: :relevance}} = Tasks.query(ctx.scope, "text ~ backend")
    assert {:ok, %{order: [{:updated, :desc}]}} = Tasks.query(ctx.scope, "status = new")

    assert {:ok, %{tasks: [_], total: 3}} =
             Tasks.query(ctx.scope, "project = BQ", limit: 1, offset: 2)
  end

  test "all legacy link queries", ctx do
    links(ctx)

    for {q, expected} <- [
          {"blocked = true", ["BQ-1"]},
          {"depends_on = ot-1", ["BQ-1"]},
          {"depends_on in (BQ-2, XX-9)", ["BQ-1"]},
          {"blocks is not empty", ["BQ-2", "OT-1"]},
          {"replaces = BQ-3", ["OT-2"]},
          {"replaced_by = OT-2", ["BQ-3"]},
          {"status = cancelled", ["BQ-3"]}
        ],
        do: assert(Enum.sort(ids(ctx.scope, q)) == expected)

    assert length(ids(ctx.scope, "blocked = false")) == 4

    for q <- ["blocked = maybe", "depends_on ~ x"],
        do: assert({:error, {:invalid_bql, _}} = Tasks.query(ctx.scope, q))
  end

  test "legacy saved filter lifecycle adapted to workspace ownership and numeric IDs", ctx do
    assert {:ok, f} = Filters.create(ctx.scope, %{name: "我的新任务", bql: "status = new"})
    assert is_integer(f.id)
    assert {:error, c} = Filters.create(ctx.scope, %{name: "x", bql: "foo = 1"})
    assert errors_on(c).bql == ["unknown field 'foo' (position 1)"]
    assert {:error, c} = Filters.create(ctx.scope, %{bql: "status = new"})
    assert errors_on(c).name == ["can't be blank"]
    assert {:ok, %{mine: [_], shared: []}} = Filters.list(ctx.scope)
    assert {:ok, %{total: 4}} = Tasks.query(ctx.scope, f)
    assert {:ok, updated} = Filters.update(ctx.scope, f.id, %{bql: "status = verified"})
    assert updated.name == "我的新任务"
    assert {:ok, %{tasks: []}} = Tasks.query(ctx.scope, f)
    assert {:error, c} = Filters.update(ctx.scope, f.id, %{bql: "("})
    assert errors_on(c).bql == ["expected a field (position 2)"]
    assert {:ok, _} = Filters.delete(ctx.scope, f.id)
    assert {:error, :not_found} = Filters.delete(ctx.scope, f.id)
    assert {:error, :not_found} = Tasks.query(ctx.scope, f)
    assert {:ok, %{mine: [], shared: []}} = Filters.list(ctx.scope)
    # Unlike bosun's standalone filter dataset, this workspace already has
    # a DONE task; use VERIFIED above to preserve the empty-result assertion.
  end
end
