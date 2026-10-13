defmodule Helmsman.Autopilots.PruneTest do
  # add-autopilots 2.3: old skipped records without a delivery ID go.
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AutopilotsFixtures

  alias Helmsman.Autopilots.{Record, State}
  alias Helmsman.Autopilots.Workers.Prune

  test "31-day-old skipped records without a delivery ID are deleted, the rest kept" do
    ctx = autopilots_fixture()
    view = autopilot_fixture(ctx.alice_scope)
    now = ~U[2026-11-30 00:00:00.000000Z]
    old = DateTime.add(now, -31 * 86_400)
    recent = DateTime.add(now, -29 * 86_400)
    a = autopilot_row(view)

    insert = fn attrs ->
      Repo.insert!(
        struct!(
          Record,
          Map.merge(
            %{
              workspace_id: a.workspace_id,
              autopilot_id: a.id,
              source: :schedule,
              config: State.snapshot(a)
            },
            attrs
          )
        )
      )
    end

    gone = insert.(%{status: :skipped, reason: "missed", inserted_at: old, updated_at: old})

    kept = [
      insert.(%{status: :skipped, reason: "overlap", inserted_at: recent, updated_at: recent}),
      insert.(%{
        source: :webhook,
        delivery_id: "d-1",
        status: :skipped,
        reason: "overlap",
        inserted_at: old,
        updated_at: old
      }),
      insert.(%{
        source: :webhook,
        delivery_id: "d-2",
        status: :skipped,
        reason: "superseded",
        inserted_at: old,
        updated_at: old
      }),
      insert.(%{status: :failed, reason: "run_failed", inserted_at: old, updated_at: old})
    ]

    at(now)
    assert :ok = perform_job(Prune, %{})

    ids = Enum.map(records_of(view), & &1.id)
    refute gone.id in ids
    assert Enum.sort(ids) == Enum.sort(Enum.map(kept, & &1.id))
  end
end
