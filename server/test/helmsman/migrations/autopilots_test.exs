defmodule Helmsman.Migrations.AutopilotsTest do
  # add-autopilots 1.1: the tables' foreign keys, checks and unique indexes.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run = run_fixture(ctx.agent, %{task_id: task.id})

    # Another workspace with its own agent, project, task and run.
    other_user = user_fixture()
    other_ws = workspace_fixture(other_user)
    other_scope = workspace_scope_fixture(other_user, other_ws)
    other_project = project_fixture(other_scope)
    other_task = task_fixture(other_scope, other_project.key)
    Helmsman.AgentsFixtures.managed_agent_fixture(other_scope, %{name: "keel/other"})
    other_agent = agent_actor(other_ws, "keel/other")
    other_run = run_fixture(other_agent, %{task_id: other_task.id})

    Map.merge(ctx, %{
      task: task,
      run: run,
      other: %{agent: other_agent, project: other_project, task: other_task, run: other_run}
    })
  end

  defp insert_autopilot(ctx, overrides) do
    cols =
      Map.merge(
        %{
          "workspace_id" => ctx.workspace.id,
          "name" => "a-#{System.unique_integer([:positive])}",
          "agent_id" => ctx.agent.id,
          "project_id" => ctx.project.id,
          "mode" => "create_task",
          "title_template" => "T",
          "instructions" => "Do it",
          "enabled" => true,
          "next_run_at" => nil,
          "inserted_at" => DateTime.utc_now(),
          "updated_at" => DateTime.utc_now()
        },
        overrides
      )

    {keys, values} = Enum.unzip(cols)
    params = Enum.map_join(1..length(keys), ", ", &"$#{&1}")

    Repo.query(
      "INSERT INTO autopilots (#{Enum.join(keys, ", ")}) VALUES (#{params}) RETURNING id",
      values
    )
  end

  defp autopilot!(ctx, overrides \\ %{}) do
    {:ok, %{rows: [[id]]}} = insert_autopilot(ctx, overrides)
    id
  end

  defp insert_record(ctx, autopilot_id, overrides) do
    cols =
      Map.merge(
        %{
          "workspace_id" => ctx.workspace.id,
          "autopilot_id" => autopilot_id,
          "source" => "manual",
          "status" => "skipped",
          "config" => %{},
          "inserted_at" => DateTime.utc_now(),
          "updated_at" => DateTime.utc_now()
        },
        overrides
      )

    {keys, values} = Enum.unzip(cols)
    params = Enum.map_join(1..length(keys), ", ", &"$#{&1}")

    Repo.query(
      "INSERT INTO autopilot_runs (#{Enum.join(keys, ", ")}) VALUES (#{params})",
      values
    )
  end

  defp code(result) do
    assert {:error, %Postgrex.Error{postgres: %{code: code} = pg}} = result
    {code, pg[:constraint]}
  end

  test "an agent or project of another workspace is refused", ctx do
    assert {:foreign_key_violation, _} =
             code(insert_autopilot(ctx, %{"agent_id" => ctx.other.agent.id}))

    assert {:foreign_key_violation, _} =
             code(insert_autopilot(ctx, %{"project_id" => ctx.other.project.id}))
  end

  test "a record's task or run of another workspace is refused", ctx do
    id = autopilot!(ctx)

    assert {:foreign_key_violation, _} =
             code(insert_record(ctx, id, %{"task_id" => ctx.other.task.id}))

    assert {:foreign_key_violation, _} =
             code(insert_record(ctx, id, %{"run_id" => ctx.other.run.id}))

    assert {:ok, _} =
             insert_record(ctx, id, %{"task_id" => ctx.task.id, "run_id" => ctx.run.id})
  end

  test "at most one started and one pending record per autopilot", ctx do
    id = autopilot!(ctx)
    assert {:ok, _} = insert_record(ctx, id, %{"status" => "started"})

    assert {:unique_violation, "autopilot_runs_one_started_index"} =
             code(insert_record(ctx, id, %{"status" => "started"}))

    assert {:ok, _} = insert_record(ctx, id, %{"status" => "pending"})

    assert {:unique_violation, "autopilot_runs_one_pending_index"} =
             code(insert_record(ctx, id, %{"status" => "pending"}))
  end

  test "a delivery ID and a scheduled time once per autopilot; empty ones repeat", ctx do
    id = autopilot!(ctx)
    at = ~U[2026-10-14 01:00:00.000000Z]
    assert {:ok, _} = insert_record(ctx, id, %{"delivery_id" => "d-1"})
    assert {:unique_violation, _} = code(insert_record(ctx, id, %{"delivery_id" => "d-1"}))
    assert {:ok, _} = insert_record(ctx, id, %{"scheduled_for" => at})
    assert {:unique_violation, _} = code(insert_record(ctx, id, %{"scheduled_for" => at}))
    assert {:ok, _} = insert_record(ctx, id, %{})
    assert {:ok, _} = insert_record(ctx, id, %{})
  end

  test "create_task needs a project; disabled means no next time; instructions ≤ 16 KB", ctx do
    assert {:check_violation, "autopilots_create_task_check"} =
             code(insert_autopilot(ctx, %{"project_id" => nil}))

    assert {:ok, _} = insert_autopilot(ctx, %{"project_id" => nil, "mode" => "run_only"})

    assert {:check_violation, "autopilots_schedule_check"} =
             code(
               insert_autopilot(ctx, %{"enabled" => false, "next_run_at" => DateTime.utc_now()})
             )

    assert {:check_violation, "autopilots_instructions_length"} =
             code(insert_autopilot(ctx, %{"instructions" => String.duplicate("x", 17_000)}))
  end

  test "names are unique in a workspace whatever the case", ctx do
    autopilot!(ctx, %{"name" => "Nightly"})

    assert {:unique_violation, "autopilots_workspace_id_name_index"} =
             code(insert_autopilot(ctx, %{"name" => "nightly"}))
  end

  test "deleting a task clears only the record's task", ctx do
    id = autopilot!(ctx)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    assert {:ok, _} = insert_record(ctx, id, %{"task_id" => task.id})
    Repo.query!("DELETE FROM task_events WHERE task_id = $1", [task.id])
    Repo.query!("DELETE FROM tasks WHERE id = $1", [task.id])

    assert %{rows: [[nil, ws]]} =
             Repo.query!(
               "SELECT task_id, workspace_id FROM autopilot_runs WHERE autopilot_id = $1",
               [id]
             )

    assert ws == ctx.workspace.id
  end
end
