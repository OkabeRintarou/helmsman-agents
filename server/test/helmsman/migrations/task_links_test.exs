defmodule Helmsman.Migrations.TaskLinksTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.LinksFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors

  setup do
    ctx = links_fixture()
    [a, b] = tasks!(ctx.alice, "BOS", 2)
    Map.merge(ctx, %{a: a, b: b})
  end

  defp insert(ws_id, from_id, to_id, type, actor_id) do
    Repo.query(
      "INSERT INTO task_links (workspace_id, from_task_id, to_task_id, type, actor_id) " <>
        "VALUES ($1, $2, $3, $4, $5)",
      [ws_id, from_id, to_id, type, actor_id]
    )
  end

  defp code(result) do
    assert {:error, %Postgrex.Error{postgres: %{code: code, constraint: constraint}}} = result
    {code, constraint}
  end

  test "a valid link; the primary key refuses a duplicate, not the other type", ctx do
    ws = ctx.workspace.id
    actor = ctx.alice.actor.id
    assert {:ok, _} = insert(ws, ctx.a.id, ctx.b.id, "depends_on", actor)
    assert {:ok, _} = insert(ws, ctx.a.id, ctx.b.id, "replaces", actor)

    assert {:unique_violation, "task_links_pkey"} =
             code(insert(ws, ctx.a.id, ctx.b.id, "depends_on", actor))
  end

  test "a self link is refused", ctx do
    assert {:check_violation, "task_links_not_self"} =
             code(insert(ctx.workspace.id, ctx.a.id, ctx.a.id, "depends_on", ctx.alice.actor.id))
  end

  test "an unknown type is refused", ctx do
    assert {:check_violation, "task_links_type_check"} =
             code(insert(ctx.workspace.id, ctx.a.id, ctx.b.id, "relates", ctx.alice.actor.id))
  end

  test "ends and actor of another workspace are refused", ctx do
    other_owner = user_fixture()
    other_ws = workspace_fixture(other_owner)
    other_scope = workspace_scope_fixture(other_owner, other_ws)
    project_fixture(other_scope, key: "OTH")
    other_task = task_fixture(other_scope, "OTH")
    {:ok, other_actor} = Actors.ensure_human(other_ws, other_owner)
    ws = ctx.workspace.id
    actor = ctx.alice.actor.id

    assert {:foreign_key_violation, "task_links_to_task_id_fkey"} =
             code(insert(ws, ctx.a.id, other_task.id, "depends_on", actor))

    assert {:foreign_key_violation, "task_links_from_task_id_fkey"} =
             code(insert(ws, other_task.id, ctx.a.id, "depends_on", actor))

    assert {:foreign_key_violation, "task_links_actor_id_fkey"} =
             code(insert(ws, ctx.a.id, ctx.b.id, "depends_on", other_actor.id))
  end
end
