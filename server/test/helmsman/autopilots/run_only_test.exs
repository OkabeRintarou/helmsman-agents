defmodule Helmsman.Autopilots.RunOnlyTest do
  # add-autopilots 5.1: run-only runs (decision 11; specs/autopilot-execution
  # "仅运行模式").
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AutopilotsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Autopilots
  alias Helmsman.Runs
  alias Helmsman.Runs.{Retry, Run, Spec}
  alias Helmsman.Tasks.Task
  alias HelmsmanMCP.{Pipeline, Sessions}

  setup do
    ctx = autopilots_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{title: "Existing"})
    Map.put(ctx, :task, task)
  end

  defp run_only(ctx, attrs \\ %{}),
    do:
      autopilot_fixture(
        ctx.alice_scope,
        Map.merge(
          %{mode: "run_only", project: nil, instructions: "Check the dependencies."},
          attrs
        )
      )

  defp session(run) do
    run = Repo.update!(Ecto.Changeset.change(run, status: :running))
    {scope, _token} = run_scope_fixture(run)
    sid = "test-#{System.unique_integer([:positive])}"
    :ok = Sessions.register(sid, scope, self())
    %{scope: scope, sid: sid}
  end

  defp call(%{scope: scope, sid: sid}, name, args), do: Pipeline.call_tool(name, args, scope, sid)

  test "a weekly look at the dependencies: a queued run without a task, priority 1, read only",
       ctx do
    view = run_only(ctx)
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id, "only the web package")

    run = Repo.get!(Run, record.run_id)

    assert {run.status, run.task_id, run.priority, run.capabilities} ==
             {:queued, nil, 1, ["read"]}

    assert [
             %{
               "kind" => "autopilot",
               "autopilot_id" => id,
               "autopilot_run_id" => rid,
               "source" => "manual",
               "create_tasks" => false
             }
           ] =
             run.triggers

    assert {id, rid} == {view.id, record.id}
    assert run.root_initiator_user_id == ctx.alice.id
    assert Repo.aggregate(Task, :count) == 1

    {:ok, spec} = Spec.build(%{run | status: :claimed}, "hmr_token", "https://hm.test")
    assert spec.prompt =~ "Check the dependencies."
    assert spec.prompt =~ "Note from #{ctx.alice_scope.actor.name}:\n\n> only the web package"
  end

  test "it may not write tasks: add_feedback and create_task are forbidden", ctx do
    view = run_only(ctx)
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    session = session(Repo.get!(Run, record.run_id))

    assert {:error, _} = call(session, "add_feedback", %{task_id: ctx.task.ident, content: "x"})
    assert {:error, _} = call(session, "create_task", %{project_key: ctx.project.key, title: "T"})
    assert Repo.aggregate(Task, :count) == 1
  end

  test "create_tasks ticked on the autopilot, not on the agent: it may create tasks", ctx do
    refute "create_tasks" in (profile(ctx.agent).capabilities || [])
    view = run_only(ctx, %{create_tasks: true})
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    run = Repo.get!(Run, record.run_id)
    assert run.capabilities == ["read", "create_tasks"]

    session = session(run)

    assert {:ok, json} =
             call(session, "create_task", %{project_key: ctx.project.key, title: "Found"})

    ident = Jason.decode!(json)["id"]
    assert Repo.get_by!(Task, ident: ident).created_by_id == ctx.agent.id
  end

  test "no retries: none automatic, a manual one is not_retryable; failed / run_failed", ctx do
    view = run_only(ctx)
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)

    run =
      Repo.get!(Run, record.run_id)
      |> Ecto.Changeset.change(
        status: :failed,
        failure_reason: :timeout,
        finished_at: DateTime.utc_now()
      )
      |> Repo.update!()

    refute Retry.automatic?(run)
    assert Runs.retry(ctx.alice_scope, run.id) == {:error, :not_retryable}

    {:ok, _} = Autopilots.settle(view.id)
    assert %{status: :failed, reason: "run_failed", result: "timeout"} = Repo.reload!(record)
  end

  test "succeeded: the result is the run's summary", ctx do
    view = run_only(ctx)
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)

    Repo.update_all(from(r in Run, where: r.id == ^record.run_id),
      set: [status: :succeeded, summary: "All up to date.", finished_at: DateTime.utc_now()]
    )

    {:ok, _} = Autopilots.settle(view.id)
    assert %{status: :succeeded, result: "All up to date."} = Repo.reload!(record)
  end

  test "disabled while queued: the run cancelled (obsolete), the record autopilot_disabled",
       ctx do
    view = run_only(ctx)
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    {:ok, _} = Autopilots.disable(ctx.alice_scope, view.id)

    assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, record.run_id)
    assert %{status: :cancelled, reason: "autopilot_disabled"} = Repo.reload!(record)
  end
end
