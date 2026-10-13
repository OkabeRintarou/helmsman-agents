defmodule Helmsman.Autopilots.RunNowTest do
  # add-autopilots 3.3: "run now" (specs/autopilots "手动触发").
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.AutopilotsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Autopilots
  alias Helmsman.Tasks.Task

  setup do
    autopilots_fixture()
  end

  test "trying a disabled autopilot: a manual record succeeds, it stays disabled", ctx do
    view = autopilot_fixture(ctx.alice_scope)

    Repo.update_all(from(a in Autopilots.Autopilot, where: a.id == ^view.id),
      set: [enabled: false, disabled_reason: :consecutive_failures, consecutive_failures: 5]
    )

    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id, "fixed it")
    assert {record.source, record.status, record.note} == {:manual, :started, "fixed it"}

    assert Repo.get!(Task, record.task_id).description =~
             "Note from #{ctx.alice_scope.actor.name}:\n\n> fixed it"

    Repo.update_all(from(t in Task, where: t.id == ^record.task_id), set: [status: :done])
    {:ok, _} = Autopilots.settle(view.id)

    assert %{status: :succeeded} = Repo.reload!(record)
    row = autopilot_row(view)
    assert {row.enabled, row.consecutive_failures} == {false, 0}
  end

  test "someone who may not trigger the target: forbidden, no record", ctx do
    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/triage",
      runtime_id: profile(ctx.agent).runtime_id,
      access: "owner_only"
    })

    view = autopilot_fixture(ctx.alice_scope, %{agent: "keel/triage"})
    assert Autopilots.run_now(ctx.bob_scope, view.id) == {:error, :forbidden}
    assert records_of(view) == []
  end

  test "a note over 4 KB is refused", ctx do
    view = autopilot_fixture(ctx.alice_scope)

    assert {:error, changeset} =
             Autopilots.run_now(ctx.alice_scope, view.id, String.duplicate("é", 2049))

    assert %{note: [_]} = errors_on(changeset)
    assert records_of(view) == []
  end

  test "an unknown autopilot or another workspace's: not_found", ctx do
    assert Autopilots.run_now(ctx.alice_scope, -1) == {:error, :not_found}
    other = autopilots_fixture()
    view = autopilot_fixture(other.alice_scope)
    assert Autopilots.run_now(ctx.alice_scope, view.id) == {:error, :not_found}
  end
end
