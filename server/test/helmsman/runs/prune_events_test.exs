defmodule Helmsman.Runs.PruneEventsTest do
  # add-run-lifecycle 4.4: execution events go 30 days after the run ended
  # (decision 17).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.RunsFixtures

  alias Helmsman.Runs
  alias Helmsman.Runs.{Run, RunEvent}
  alias Helmsman.Runs.Workers.PruneEvents

  setup do
    dispatch_fixture()
  end

  defp ended(ctx, days_ago, events \\ 2) do
    run =
      run_fixture(ctx.agent, %{
        status: :succeeded,
        finished_at: DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second),
        events_seq: events
      })

    rows =
      for seq <- 1..events//1,
          do: %{
            run_id: run.id,
            seq: seq,
            type: "text",
            data: %{"text" => "x"},
            at: DateTime.utc_now()
          }

    Repo.insert_all(RunEvent, rows)
    run
  end

  defp events(run), do: Repo.aggregate(from(e in RunEvent, where: e.run_id == ^run.id), :count)

  test "a run that ended 31 days ago loses its events, not its record (scenario)", ctx do
    old = ended(ctx, 31)
    recent = ended(ctx, 29)
    running = run_fixture(ctx.agent, %{status: :running})

    assert :ok = perform_job(PruneEvents, %{})

    assert events(old) == 0
    assert %Run{events_pruned_at: %DateTime{}} = Repo.get!(Run, old.id)
    assert events(recent) == 2
    assert Repo.get!(Run, running.id).events_pruned_at == nil

    assert {:ok, %{id: _}} = Runs.get(ctx.alice_scope, old.id)

    assert {:ok, %{events: [], pruned: true, last_seq: 2}} =
             Runs.list_events(ctx.alice_scope, old.id)

    assert {:ok, %{events: [_, _], pruned: false}} = Runs.list_events(ctx.alice_scope, recent.id)
  end

  test "in batches of 100 until none is left", ctx do
    runs = for _ <- 1..230, do: ended(ctx, 40, 1)
    assert :ok = perform_job(PruneEvents, %{})

    ids = Enum.map(runs, & &1.id)
    assert Repo.aggregate(from(e in RunEvent, where: e.run_id in ^ids), :count) == 0

    assert Repo.aggregate(
             from(r in Run, where: r.id in ^ids and is_nil(r.events_pruned_at)),
             :count
           ) ==
             0
  end
end
