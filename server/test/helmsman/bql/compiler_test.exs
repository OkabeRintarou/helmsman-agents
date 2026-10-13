defmodule Helmsman.BQL.CompilerTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AgentsFixtures
  import Helmsman.BQLFixtures
  import Helmsman.RunsFixtures, only: [run_fixture: 2]
  alias Helmsman.Actors.Actor
  alias Helmsman.{Feedback, Tasks}

  setup do
    bql_fixture() |> links()
  end

  defp ids(scope, q) do
    assert {:ok, result} = Tasks.query(scope, q)
    MapSet.new(result.tasks, & &1.id)
  end

  test "nullable and multivalue predicates have exact complements", ctx do
    all = ids(ctx.scope, "")

    for q <- [
          "labels = backend",
          "labels IN (backend,mcp)",
          "labels ~ back",
          "labels IS EMPTY",
          "assignee = user",
          "assignee IN (user)",
          "assignee ~ use",
          "assignee IS EMPTY",
          "epic = OT-2",
          "epic IN (OT-2)",
          "epic IS EMPTY",
          "assignee_kind = human",
          "owner = user",
          "owner IN (user)",
          "run = failed",
          "run IN (failed)",
          "run IS EMPTY",
          "pr = open",
          "ci = success",
          "merge = waiting",
          "depends_on = OT-1",
          "blocks IN (BQ-1)",
          "replaces IS EMPTY",
          "replaced_by = OT-2",
          "feedback ~ port",
          "feedback IS EMPTY",
          "description IS EMPTY",
          "blocked = true",
          "text ~ backend"
        ] do
      a = ids(ctx.scope, q)
      b = ids(ctx.scope, "NOT (#{q})")
      assert MapSet.disjoint?(a, b), q
      assert MapSet.union(a, b) == all, q
    end

    for {q, expected} <- [
          {"labels != mcp", ~w(BQ-2 BQ-3 OT-1 OT-2)},
          {"assignee != user", ~w(BQ-1 BQ-3 OT-1 OT-2)},
          {"assignee NOT IN (user)", ~w(BQ-1 BQ-3 OT-1 OT-2)},
          {"labels !~ back", ~w(BQ-2 BQ-3 OT-2)},
          {"depends_on NOT IN (OT-1)", ~w(BQ-2 BQ-3 OT-1 OT-2)}
        ],
        do: assert(ids(ctx.scope, q) == MapSet.new(expected))
  end

  test "enum comparisons, identity kinds, booleans and literals", ctx do
    for {q, expected} <- [
          {"priority > medium", ["BQ-1"]},
          {"priority >= high", ["BQ-1"]},
          {"priority < medium", ["BQ-3"]},
          {"priority <= low", ["BQ-3"]},
          {"created_by_kind = agent", ["BQ-1"]},
          {"assignee_kind = human", ["BQ-2"]},
          {"owner = user", ["BQ-2"]},
          {"feedback_count = 1", ["BQ-3"]},
          {"question = yes", ["BQ-3"]},
          {"blocked != no", ["BQ-1"]},
          {"id ~ bq", ~w(BQ-1 BQ-2 BQ-3)},
          {"title = \"Write docs\"", ["BQ-2"]},
          {"description IS EMPTY", ~w(BQ-1 BQ-2 BQ-3 OT-1 OT-2)}
        ],
        do: assert(ids(ctx.scope, q) == MapSet.new(expected))

    for q <- [
          "project = nobody",
          "assignee = nobody",
          "owner = nobody",
          "epic = XX-99",
          "depends_on = XX-99"
        ],
        do: assert(ids(ctx.scope, q) == MapSet.new())

    assert ids(ctx.scope, ~S(title = "x' OR '1'='1")) == MapSet.new()
    {:ok, _} = Tasks.update(ctx.scope, ctx.bq1.ident, %{title: "x' OR '1'='1"})
    assert ids(ctx.scope, ~S(title = "x' OR '1'='1")) == MapSet.new(["BQ-1"])

    {:ok, _} =
      Tasks.update(ctx.scope, ctx.bq1.ident, %{title: "100%_done", description: "Exact percent %"})

    assert ids(ctx.scope, ~S(title ~ "%_")) == MapSet.new(["BQ-1"])
    assert ids(ctx.scope, ~S(description ~ "%")) == MapSet.new(["BQ-1"])
  end

  test "latest run across lanes and owner agents", ctx do
    managed_agent_fixture(ctx.scope, %{name: "managed"})

    agent =
      Repo.one!(
        from(a in Actor, where: a.workspace_id == ^ctx.workspace.id and a.name == "managed")
      )

    {:ok, _} = Tasks.update(ctx.scope, ctx.bq1.ident, %{assignee: "managed", start: false})

    run_fixture(agent, %{
      task_id: ctx.bq1.id,
      status: :succeeded,
      inserted_at: DateTime.add(DateTime.utc_now(), -60)
    })

    run_fixture(agent, %{
      task_id: ctx.bq1.id,
      status: :failed,
      failure_reason: :timeout,
      lane: :reply
    })

    assert ids(ctx.scope, "run = failed") == MapSet.new(["BQ-1"])
    assert ids(ctx.scope, "run = succeeded") == MapSet.new()
    assert ids(ctx.scope, "owner = user") == MapSet.new(["BQ-1", "BQ-2"])
    assert ids(ctx.scope, "run IS EMPTY") == MapSet.new(~w(BQ-2 BQ-3 OT-1 OT-2))

    for q <- ["run != failed", "run NOT IN (failed)"],
        do: assert(ids(ctx.scope, q) == MapSet.new(~w(BQ-2 BQ-3 OT-1 OT-2)))
  end

  test "only active feedback contributes to count and fulltext", ctx do
    assert {:ok, _} =
             Feedback.revise(%{ctx.scope | actor: ctx.keel}, "BQ-3#1", %{
               content: "revised unique"
             })

    assert ids(ctx.scope, "feedback ~ port") == MapSet.new()
    assert ids(ctx.scope, "text ~ port") == MapSet.new()
    assert ids(ctx.scope, "feedback ~ revised") == MapSet.new(["BQ-3"])
    assert ids(ctx.scope, "feedback_count = 1") == MapSet.new(["BQ-3"])
    assert ids(ctx.scope, "question = true") == MapSet.new(["BQ-3"])
  end

  test "PR, CI and merge use the latest row; none counts as empty" do
    ctx = Helmsman.PullRequestFixtures.pr_fixture()

    Helmsman.PullRequestFixtures.pr_row(ctx, %{
      state: :merged,
      checks_state: :success,
      merge_status: :merged
    })

    current =
      Helmsman.PullRequestFixtures.pr_row(ctx, %{
        state: :open,
        checks_state: :pending,
        merge_status: :waiting,
        merge_reason: :ci_pending
      })

    empty = Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, ctx.project.key)

    assert ids(ctx.alice_scope, "pr = open AND ci = pending AND merge = waiting") ==
             MapSet.new([ctx.task.ident])

    assert ids(ctx.alice_scope, "pr = merged") == MapSet.new()

    for q <- [
          "pr IS EMPTY",
          "ci IS EMPTY",
          "merge IS EMPTY",
          "pr != open",
          "ci NOT IN (pending)",
          "merge != waiting"
        ],
        do: assert(ids(ctx.alice_scope, q) == MapSet.new([empty.ident]))

    Repo.update_all(from(p in Helmsman.GitHub.PullRequest, where: p.id == ^current.id),
      set: [checks_state: :none, merge_status: :none, merge_reason: nil]
    )

    for q <- ["ci IS EMPTY", "merge IS EMPTY"],
        do: assert(ids(ctx.alice_scope, q) == MapSet.new([empty.ident, ctx.task.ident]))
  end
end
