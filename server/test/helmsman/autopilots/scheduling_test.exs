defmodule Helmsman.Autopilots.SchedulingTest do
  # add-autopilots 2.2: planning and scheduled triggers (decisions 5, 6).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AutopilotsFixtures

  alias Helmsman.Autopilots
  alias Helmsman.Autopilots.Workers.{Fire, Sweep}

  setup do
    autopilots_fixture()
  end

  defp fire(view, at),
    do: perform_job(Fire, %{autopilot_id: view.id, at: DateTime.to_iso8601(at)})

  defp fire_jobs(view) do
    for %{args: %{"autopilot_id" => id, "at" => at}} <- all_enqueued(worker: Fire),
        id == view.id,
        do: at
  end

  test "after the cron changed, the old trigger does nothing; the new one fires", ctx do
    at(~U[2026-10-14 07:00:00Z])
    view = autopilot_fixture(ctx.alice_scope, %{cron: "0 9 * * *"})
    assert view.next_run_at == ~U[2026-10-14 09:00:00.000000Z]

    at(~U[2026-10-14 08:00:00Z])
    {:ok, view} = Autopilots.update(ctx.alice_scope, view.id, %{cron: "0 10 * * *"})
    assert view.next_run_at == ~U[2026-10-14 10:00:00.000000Z]

    at(~U[2026-10-14 09:00:00Z])
    assert :ok = fire(view, ~U[2026-10-14 09:00:00.000000Z])
    assert records_of(view) == []

    at(~U[2026-10-14 10:00:01Z])
    assert :ok = fire(view, ~U[2026-10-14 10:00:00.000000Z])

    assert [
             %{
               source: :schedule,
               status: :started,
               scheduled_for: ~U[2026-10-14 10:00:00.000000Z]
             }
           ] =
             records_of(view)

    assert autopilot_row(view).next_run_at == ~U[2026-10-15 10:00:00.000000Z]
  end

  test "down for 40 minutes: fires once at 09:40 for 09:00, next tomorrow", ctx do
    at(~U[2026-10-14 08:00:00Z])
    view = autopilot_fixture(ctx.alice_scope, %{cron: "0 9 * * *"})

    at(~U[2026-10-14 09:40:00Z])
    assert :ok = fire(view, ~U[2026-10-14 09:00:00.000000Z])

    assert [%{status: :started, scheduled_for: ~U[2026-10-14 09:00:00.000000Z]}] =
             records_of(view)

    assert autopilot_row(view).next_run_at == ~U[2026-10-15 09:00:00.000000Z]
    assert "2026-10-15T09:00:00.000000Z" in fire_jobs(view)
  end

  test "down for 3 hours: one skipped / missed, next from now", ctx do
    at(~U[2026-10-14 08:55:00Z])
    view = autopilot_fixture(ctx.alice_scope, %{cron: "*/10 * * * *"})
    assert view.next_run_at == ~U[2026-10-14 09:00:00.000000Z]

    at(~U[2026-10-14 12:03:00Z])
    assert :ok = fire(view, ~U[2026-10-14 09:00:00.000000Z])

    assert [%{status: :skipped, reason: "missed"}] = records_of(view)
    assert autopilot_row(view).next_run_at == ~U[2026-10-14 12:10:00.000000Z]
    # No task was created.
    assert Repo.aggregate(Helmsman.Tasks.Task, :count) == 0
  end

  test "a lost schedule is planned again by the sweep, without duplicates", ctx do
    at(~U[2026-10-14 08:00:00Z])
    view = autopilot_fixture(ctx.alice_scope, %{cron: "0 9 * * *"})
    Repo.delete_all(Oban.Job)

    assert :ok = perform_job(Sweep, %{})
    assert fire_jobs(view) == ["2026-10-14T09:00:00.000000Z"]

    assert :ok = perform_job(Sweep, %{})
    assert fire_jobs(view) == ["2026-10-14T09:00:00.000000Z"]

    # A missing next time is computed again.
    Repo.update_all(from(a in Autopilots.Autopilot, where: a.id == ^view.id),
      set: [next_run_at: nil]
    )

    Repo.delete_all(Oban.Job)
    assert :ok = perform_job(Sweep, %{})
    assert autopilot_row(view).next_run_at == ~U[2026-10-14 09:00:00.000000Z]
    assert fire_jobs(view) == ["2026-10-14T09:00:00.000000Z"]
  end

  test "the same (id, at) fired twice leaves one record", ctx do
    at(~U[2026-10-14 08:00:00Z])
    view = autopilot_fixture(ctx.alice_scope, %{cron: "0 9 * * *"})
    at(~U[2026-10-14 09:00:00Z])
    assert :ok = fire(view, ~U[2026-10-14 09:00:00.000000Z])
    assert :ok = fire(view, ~U[2026-10-14 09:00:00.000000Z])
    assert length(records_of(view)) == 1
  end

  test "after disabling, the planned triggers do nothing", ctx do
    at(~U[2026-10-14 08:00:00Z])
    view = autopilot_fixture(ctx.alice_scope, %{cron: "0 9 * * *"})
    {:ok, _} = Autopilots.disable(ctx.alice_scope, view.id)

    at(~U[2026-10-14 09:00:00Z])

    for at <- fire_jobs(view),
        do: assert(:ok = perform_job(Fire, %{autopilot_id: view.id, at: at}))

    assert records_of(view) == []
  end

  test "without a cron nothing is planned", ctx do
    view = autopilot_fixture(ctx.alice_scope)
    assert view.next_run_at == nil
    assert fire_jobs(view) == []
  end
end
