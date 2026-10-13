defmodule Helmsman.Autopilots.RunSummaryTest do
  # add-autopilots decision 11 in the run read model (add-squads-autopilots-ui
  # domain-request-1 R4): the autopilot trigger names its autopilot and source,
  # and such a run is never retryable.
  use Helmsman.DataCase, async: true

  import Helmsman.AutopilotsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Autopilots
  alias Helmsman.Runs
  alias Helmsman.Runs.Run

  setup do
    ctx = autopilots_fixture()

    view =
      autopilot_fixture(ctx.alice_scope, %{name: "deps-check", mode: "run_only", project: nil})

    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    Map.merge(ctx, %{view: view, run: Repo.get!(Run, record.run_id)})
  end

  test "the trigger carries the autopilot and the source; deleted → nil", ctx do
    id = ctx.view.id

    assert [%{kind: "autopilot", autopilot: %{id: ^id, name: "deps-check"}, source: "manual"}] =
             Runs.summary(ctx.run).triggers

    manual = trigger("manual", ctx.workspace, ctx.alice, ctx.agent)
    plain = run_fixture(ctx.agent, %{status: :failed, triggers: [manual]})

    assert [[%{autopilot: %{id: ^id}}], [plain_trigger]] =
             Enum.map(Runs.summaries([ctx.run, plain]), & &1.triggers)

    refute Map.has_key?(plain_trigger, :autopilot)

    assert :ok = delete(ctx)

    assert [%{kind: "autopilot", autopilot: nil, source: "manual"}] =
             Runs.summary(Repo.get!(Run, ctx.run.id)).triggers
  end

  test "an autopilot id of another workspace is never named", ctx do
    other = autopilots_fixture()

    foreign =
      autopilot_fixture(other.alice_scope, %{name: "secret-audit", mode: "run_only", project: nil})

    [entry] = ctx.run.triggers

    forged =
      run_fixture(ctx.agent, %{
        status: :failed,
        triggers: [%{entry | "autopilot_id" => foreign.id}]
      })

    assert [%{kind: "autopilot", autopilot: nil, source: "manual"}] =
             Runs.summary(forged).triggers

    id = ctx.view.id

    assert [[%{autopilot: %{id: ^id}}], [%{autopilot: nil}]] =
             Enum.map(Runs.summaries([ctx.run, forged]), & &1.triggers)
  end

  test "can?: an autopilot run may be stopped but never retried", ctx do
    summary = Runs.summary(ctx.run)
    refute Runs.can?(ctx.alice_scope, :retry, summary)
    assert Runs.can?(ctx.alice_scope, :cancel, summary)

    plain = run_fixture(ctx.agent, %{status: :failed})
    assert Runs.can?(ctx.alice_scope, :retry, Runs.summary(plain))
  end

  defp delete(ctx) do
    case Autopilots.delete(ctx.alice_scope, ctx.view.id) do
      {:ok, _} -> :ok
      other -> other
    end
  end
end
