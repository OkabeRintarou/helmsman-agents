defmodule Helmsman.Runs.RevalidationAutopilotTest do
  # add-autopilots 5.2: a run-only run whose record is gone or settled is
  # obsolete when claimed or about to start (decision 11).
  use Helmsman.DataCase, async: true

  import Helmsman.AutopilotsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Autopilots
  alias Helmsman.Autopilots.Record
  alias Helmsman.Runs
  alias Helmsman.Runs.Run

  setup do
    ctx = autopilots_fixture()
    view = autopilot_fixture(ctx.alice_scope, %{mode: "run_only", project: nil})
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    Map.merge(ctx, %{view: view, record: record})
  end

  defp claim(ctx), do: Runs.claim(daemon_ctx(daemon_of(ctx.agent)), "http://localhost:4000")

  test "a current record: claimed", ctx do
    assert {:ok, [%{run_id: id}]} = claim(ctx)
    assert id == ctx.record.run_id
  end

  test "claiming: the record deleted → obsolete", ctx do
    Repo.delete_all(from(r in Record, where: r.id == ^ctx.record.id))
    assert {:ok, []} = claim(ctx)
    assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, ctx.record.run_id)
  end

  test "claiming: the record settled → obsolete", ctx do
    Repo.update_all(from(r in Record, where: r.id == ^ctx.record.id), set: [status: :cancelled])
    assert {:ok, []} = claim(ctx)
    assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, ctx.record.run_id)
  end

  test "about to start: the record settled meanwhile → obsolete", ctx do
    assert {:ok, [%{run_id: run_id}]} = claim(ctx)
    Repo.update_all(from(r in Record, where: r.id == ^ctx.record.id), set: [status: :failed])
    assert {:ok, {:abort, "obsolete"}} = Runs.starting(dctx(ctx.agent), run_id)
    refute Repo.get!(Run, run_id).status == :running
  end
end
