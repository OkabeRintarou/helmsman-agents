defmodule Helmsman.Runs.ListFinishedTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{QueryCount, Runs}

  setup do
    ctx = dispatch_fixture()
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.merge(ctx, %{viewer_scope: viewer_scope, task: task, at: DateTime.utc_now()})
  end

  defp ids(summaries), do: Enum.map(summaries, & &1.id)
  defp cursor(summary), do: {summary.inserted_at, summary.id}

  defp read(scope, target, wanted, before \\ nil, acc \\ []) do
    {:ok, %{runs: page, total: total}} =
      Runs.list_finished(scope, target, limit: 50, before: before)

    acc = acc ++ [{page, total}]
    count = acc |> Enum.map(&length(elem(&1, 0))) |> Enum.sum()

    if page == [] or count >= wanted,
      do: acc,
      else: read(scope, target, wanted, cursor(List.last(page)), acc)
  end

  test "pages without repeats; a run that ends meanwhile shows when read again", ctx do
    statuses = Stream.cycle([:succeeded, :failed, :cancelled])

    finished =
      for {status, n} <- Enum.zip(statuses, 1..120) do
        run_fixture(ctx.agent, %{
          task_id: ctx.task.id,
          status: status,
          inserted_at: DateTime.add(ctx.at, n)
        })
      end

    # Queued, created between the 30th and 31st run: on the second page's side.
    late = run_fixture(ctx.agent, %{task_id: ctx.task.id, inserted_at: DateTime.add(ctx.at, 30)})
    target = {:task, ctx.task.ident}

    {:ok, %{runs: first, total: 120}} = Runs.list_finished(ctx.viewer_scope, target, limit: 50)
    Repo.update!(Ecto.Changeset.change(late, status: :succeeded, finished_at: DateTime.utc_now()))

    {:ok, %{runs: second, total: 121}} =
      Runs.list_finished(ctx.viewer_scope, target, limit: 50, before: cursor(List.last(first)))

    {:ok, %{runs: third, total: 121}} =
      Runs.list_finished(ctx.viewer_scope, target, limit: 50, before: cursor(List.last(second)))

    seen = ids(first ++ second ++ third)
    original = Enum.map(finished, & &1.id)
    assert Enum.uniq(seen) == seen
    assert Enum.all?(original, &(&1 in seen))
    assert length(first) == 50

    reread = read(ctx.viewer_scope, target, 121)
    reread_ids = reread |> Enum.flat_map(&elem(&1, 0)) |> ids()
    assert Enum.all?(reread, fn {_page, total} -> total == 121 end)

    expected =
      [late | finished]
      |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}, :desc)
      |> Enum.map(& &1.id)

    assert reread_ids == expected
  end

  test "an agent's finished runs, newest first, only ended ones", ctx do
    runs =
      for n <- 1..5,
          do: run_fixture(ctx.agent, %{status: :failed, inserted_at: DateTime.add(ctx.at, n)})

    run_fixture(ctx.agent, %{status: :running})
    run_fixture(ctx.agent, %{status: :queued})
    target = {:agent, "keel/dev"}

    assert {:ok, %{runs: page, total: 5}} =
             Runs.list_finished(ctx.viewer_scope, target, limit: 2)

    assert ids(page) == runs |> Enum.reverse() |> Enum.take(2) |> Enum.map(& &1.id)

    assert {:ok, %{runs: rest, total: 5}} =
             Runs.list_finished(ctx.viewer_scope, target, before: cursor(List.last(page)))

    assert ids(rest) == runs |> Enum.reverse() |> Enum.drop(2) |> Enum.map(& &1.id)
  end

  test "the number of queries does not depend on the number of runs", ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/busy"})
    busy = agent_actor(ctx.workspace, "keel/busy")
    run_fixture(ctx.agent, %{status: :succeeded})
    for _ <- 1..50, do: run_fixture(busy, %{status: :succeeded})

    {{:ok, small}, few} =
      QueryCount.count(fn -> Runs.list_finished(ctx.viewer_scope, {:agent, "keel/dev"}) end)

    {{:ok, large}, more} =
      QueryCount.count(fn -> Runs.list_finished(ctx.viewer_scope, {:agent, "keel/busy"}) end)

    assert few == more
    assert {length(small.runs), small.total} == {1, 1}
    assert {length(large.runs), large.total} == {50, 50}
    assert Enum.all?(large.runs, &(&1.agent == "keel/busy" and &1.status == "succeeded"))
  end

  test "unknown targets, bad options and missing permission", ctx do
    Repo.insert!(
      Actor.create_changeset(
        %Actor{workspace_id: ctx.workspace.id, owner_id: ctx.alice.id, kind: :agent},
        %{name: "outside/bot"}
      )
    )

    scope = ctx.viewer_scope

    for target <- [{:agent, "nope"}, {:agent, "outside/bot"}, {:task, "NOPE-1"}] do
      assert {:error, :not_found} = Runs.list_finished(scope, target)
    end

    for opts <- [
          [limit: 0],
          [limit: 101],
          [limit: "5"],
          [before: {1, 2}],
          [before: {DateTime.utc_now()}],
          [before: "x"],
          %{limit: 2}
        ] do
      assert {:error, :invalid_opts} = Runs.list_finished(scope, {:task, ctx.task.ident}, opts)
    end

    assert {:ok, %{total: 0}} = Runs.list_finished(scope, {:task, ctx.task.ident}, limit: 100)

    assert {:error, :forbidden} =
             Runs.list_finished(%{scope | role: nil}, {:task, ctx.task.ident})
  end

  test "a run of another task is not listed", ctx do
    other = task_fixture(ctx.alice_scope, ctx.project.key)
    run_fixture(ctx.agent, %{task_id: other.id, status: :succeeded})

    assert {:ok, %{runs: [], total: 0}} =
             Runs.list_finished(ctx.viewer_scope, {:task, ctx.task.ident})
  end
end
