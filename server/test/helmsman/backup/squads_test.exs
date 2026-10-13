defmodule Helmsman.Backup.SquadsTest do
  use Helmsman.DataCase, async: true
  import Helmsman.RunsFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Actors, Squads, Tasks}
  alias Helmsman.Backup.Import.Actors, as: ImportActors

  test "imported squad is disabled history with no configuration" do
    ctx = dispatch_fixture()
    data = %{"actors" => [%{"name" => "old-team", "kind" => "squad", "disabled" => false}]}
    assert {:ok, mapping, _} = ImportActors.map(ctx.alice_scope, data, %{})
    actor = mapping["old-team"]
    assert actor.kind == :squad and actor.disabled_at
    assert {:error, :squad_disabled} = Squads.trigger_check(ctx.workspace.id, ctx.alice.id, actor)
    assert {:ok, squads} = Squads.list(ctx.alice_scope)
    refute Enum.any?(squads, &(&1.name == actor.name))
    task = task_fixture(ctx.alice_scope, ctx.project.key)

    assert {:error, changeset} =
             Tasks.update(ctx.alice_scope, task.ident, %{assignee: actor.name})

    assert errors_on(changeset).assignee == ["is disabled"]
    assert Squads.assignee_side(%Tasks.Task{assignee_id: actor.id}) == [actor.id]
    assert {:ok, assignable} = Actors.list_assignable(ctx.alice_scope)
    refute Enum.any?(assignable, &(&1.id == actor.id))
  end
end
