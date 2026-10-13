defmodule Helmsman.Migrations.SquadsTest do
  # add-squads 1.1: the tables, columns and indexes of decision 2, written
  # directly to the database.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    squad_actor = insert_actor(ctx.workspace.id, "web-team")
    {:ok, %{rows: [[squad_id]]}} = insert_squad(ctx.workspace.id, squad_actor, ctx.agent.id)

    other = workspace_fixture(user_fixture())
    other_actor = insert_actor(other.id, "other-team")

    Map.merge(ctx, %{
      task: task,
      squad_actor: squad_actor,
      squad_id: squad_id,
      other: other,
      other_actor: other_actor
    })
  end

  defp insert_actor(workspace_id, name) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO actors (workspace_id, kind, name, inserted_at, updated_at) " <>
          "VALUES ($1, 'squad', $2, now(), now()) RETURNING id",
        [workspace_id, name]
      )

    id
  end

  defp insert_squad(workspace_id, actor_id, leader_id) do
    Repo.query(
      "INSERT INTO squads (workspace_id, actor_id, leader_agent_id, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, now(), now()) RETURNING id",
      [workspace_id, actor_id, leader_id]
    )
  end

  defp insert_member(workspace_id, squad_id, actor_id) do
    Repo.query(
      "INSERT INTO squad_members (workspace_id, squad_id, actor_id, position, inserted_at) " <>
        "VALUES ($1, $2, $3, 0, now())",
      [workspace_id, squad_id, actor_id]
    )
  end

  defp assert_fk(result) do
    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} = result
  end

  defp queued_run(ctx, squad_id) do
    profile = profile(ctx.agent)

    Repo.query(
      "INSERT INTO runs (workspace_id, agent_id, runtime_id, task_id, lane, status, " <>
        "root_initiator_user_id, causal_agent_ids, capabilities, priority, inserted_at, " <>
        "updated_at, squad_id) VALUES ($1, $2, $3, $4, 'work', 'queued', $5, $6, '{read}', 2, " <>
        "now(), now(), $7)",
      [
        ctx.workspace.id,
        ctx.agent.id,
        profile.runtime_id,
        ctx.task.id,
        ctx.alice.id,
        [ctx.agent.id],
        squad_id
      ]
    )
  end

  test "a squad's identity and leader must be of its workspace", ctx do
    another = insert_actor(ctx.workspace.id, "api-team")
    assert_fk(insert_squad(ctx.other.id, another, ctx.agent.id))
    assert_fk(insert_squad(ctx.workspace.id, ctx.other_actor, ctx.agent.id))
    assert {:ok, _} = insert_squad(ctx.workspace.id, another, ctx.agent.id)
  end

  test "a member must be of the squad's workspace", ctx do
    assert_fk(insert_member(ctx.workspace.id, ctx.squad_id, ctx.other_actor))
    assert_fk(insert_member(ctx.other.id, ctx.squad_id, ctx.other_actor))

    alice = human_actor(ctx.workspace, ctx.alice).id
    assert {:ok, _} = insert_member(ctx.workspace.id, ctx.squad_id, alice)
  end

  test "runs and grants refer to a squad of their workspace", ctx do
    {:ok, %{rows: [[other_squad]]}} =
      insert_squad(ctx.other.id, ctx.other_actor, insert_other_agent(ctx.other))

    assert_fk(queued_run(ctx, other_squad))

    grant = fn squad_id ->
      Repo.query(
        "INSERT INTO task_grants (workspace_id, task_id, agent_id, kind, " <>
          "root_initiator_user_id, causal_agent_ids, granted_by_id, inserted_at, squad_id) " <>
          "VALUES ($1, $2, $3, 'assign', $4, '{}', $3, now(), $5)",
        [ctx.workspace.id, ctx.task.id, ctx.squad_actor, ctx.alice.id, squad_id]
      )
    end

    assert_fk(grant.(other_squad))
    assert {:ok, _} = grant.(ctx.squad_id)
  end

  test "the pending index keeps runs as a squad apart from the others", ctx do
    assert {:ok, _} = queued_run(ctx, nil)
    assert {:ok, _} = queued_run(ctx, ctx.squad_id)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "runs_pending_index"}}} =
             queued_run(ctx, ctx.squad_id)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "runs_pending_index"}}} =
             queued_run(ctx, nil)
  end

  test "text lengths are counted in bytes", ctx do
    long = String.duplicate("😀", 513)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "squads_description_length"}}} =
             Repo.query("UPDATE squads SET description = $2 WHERE id = $1", [ctx.squad_id, long])

    assert {:ok, _} =
             Repo.query("UPDATE squads SET description = $2 WHERE id = $1", [
               ctx.squad_id,
               String.duplicate("😀", 512)
             ])
  end

  test "task events take an assignee side", ctx do
    assert {:ok, _} =
             Repo.query(
               "UPDATE task_events SET assignee_side_ids = $2 WHERE task_id = $1",
               [ctx.task.id, [ctx.squad_actor, ctx.agent.id]]
             )
  end

  # Sketch of a leader in the other workspace: an agent identity without a
  # profile is enough for the foreign keys.
  defp insert_other_agent(workspace) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO actors (workspace_id, kind, name, owner_id, inserted_at, updated_at) " <>
          "SELECT $1, 'agent', 'x/lead', user_id, now(), now() FROM memberships " <>
          "WHERE workspace_id = $1 LIMIT 1 RETURNING id",
        [workspace.id]
      )

    id
  end
end
