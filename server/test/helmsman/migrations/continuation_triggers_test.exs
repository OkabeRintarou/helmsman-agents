defmodule Helmsman.Migrations.ContinuationTriggersTest do
  # add-continuation-triggers 1.1: the columns and constraints of decision
  # 2, written directly to the database.
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Feedback.Entry
  alias Helmsman.Tasks.TaskEvent

  setup do
    ctx = dispatch_fixture()
    Map.put(ctx, :task, task_fixture(ctx.alice_scope, ctx.project.key))
  end

  defp assert_check(result, constraint) do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: ^constraint}}} =
             result
  end

  defp event_sql(task, actor_id, auto, reason) do
    Repo.query(
      "INSERT INTO task_events (workspace_id, task_id, from_status, to_status, actor_id, " <>
        "commits, auto, auto_reason, inserted_at) " <>
        "VALUES ($1, $2, 'verified', 'in_progress', $3, '{}', $4, $5, now())",
      [task.workspace_id, task.id, actor_id, auto, reason]
    )
  end

  test "defaults: wake_on_requested true, dispatch [], auto_reason nil", ctx do
    assert %AgentProfile{wake_on_requested: true} = profile(ctx.agent)

    {:ok, entry} = Helmsman.Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "x"})

    assert %Entry{dispatch: []} = Repo.get!(Entry, entry.id)

    assert [%TaskEvent{auto_reason: nil}] =
             Repo.all(from(e in TaskEvent, where: e.task_id == ^ctx.task.id))
  end

  test "auto_reason needs auto and a known reason", ctx do
    actor_id = ctx.alice_scope.actor.id

    assert_check(
      event_sql(ctx.task, actor_id, false, "ci_failed"),
      "task_events_auto_reason_check"
    )

    assert_check(event_sql(ctx.task, actor_id, true, "bogus"), "task_events_auto_reason_check")
    assert {:ok, _} = event_sql(ctx.task, actor_id, true, "merge_conflict")
    assert {:ok, _} = event_sql(ctx.task, actor_id, false, nil)
  end

  test "dispatch must be an array", ctx do
    {:ok, entry} = Helmsman.Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "x"})

    for value <- [~s({"a": 1}), ~s("x"), "null"] do
      result =
        Repo.query("UPDATE feedback SET dispatch = $2::jsonb WHERE id = $1", [entry.id, value])

      case value do
        "null" -> assert {:error, %Postgrex.Error{postgres: %{code: _}}} = result
        _ -> assert_check(result, "feedback_dispatch_check")
      end
    end
  end

  test "task_grants.kind: assign and requested only", ctx do
    insert = fn kind ->
      Repo.query(
        "INSERT INTO task_grants (workspace_id, task_id, agent_id, kind, root_initiator_user_id, " <>
          "causal_agent_ids, granted_by_id, inserted_at) VALUES ($1, $2, $3, $4, $5, $6, $3, now())",
        [ctx.workspace.id, ctx.task.id, ctx.agent.id, kind, ctx.alice.id, [ctx.agent.id]]
      )
    end

    assert {:ok, _} = insert.("assign")
    assert {:ok, _} = insert.("requested")
    assert_check(insert.("delegate"), "task_grants_kind_check")
  end

  # The migration ran its SQL, not just recorded its version
  # (code-review-1 P1).
  test "the migrated kind check" do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'task_grants_kind_check'"
      )

    assert definition =~ "'assign'"
    assert definition =~ "'requested'"
  end
end
