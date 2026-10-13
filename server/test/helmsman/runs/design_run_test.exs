defmodule Helmsman.Runs.DesignRunTest do
  # add-agent-conversation 2.1-2.3: design runs on the run side (decisions
  # 7, 10, 11).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentDesignsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{AgentDesigns, Runs}
  alias Helmsman.AgentDesigns.{AgentDesign, SettleTurn}
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Runs.{Run, RunTokens}
  alias Helmsman.Runs.Workers.{Retry, Sweep}
  alias Helmsman.Tasks.Task
  alias HelmsmanMCP.Pipeline
  alias HelmsmanMCP.Tools.CreateTask

  setup do
    ctx = design_fixture(%{capabilities: ["create_tasks"]})
    %{id: id} = start_design!(ctx.alice_scope)
    Map.put(ctx, :id, id)
  end

  defp reload(run), do: Repo.get!(Run, run.id)

  describe "enqueueing (2.1)" do
    test "priority 3, read + design even with create_tasks, the design ID, no task", ctx do
      run = current_run!(ctx.id)
      assert run.priority == 3 and run.task_id == nil
      assert run.capabilities == ["read", "design"]
      assert Runs.design_id(run) == ctx.id

      assert [spec_id] = claim!(ctx.helper)
      assert spec_id == run.id
      assert reload(run).capabilities == ["read", "design"]
    end

    test "two turns of one conversation are two runs, never merged", ctx do
      end_and_settle!(current_run!(ctx.id), :cancelled)
      {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "again")
      assert [%Run{id: a}, %Run{id: b}] = design_runs!(ctx.id)
      assert a != b
      assert length(reload(%Run{id: b}).triggers) == 1
    end

    test "a design run cannot create tasks (scenario)", ctx do
      project = project_fixture(ctx.alice_scope)
      {:ok, [spec]} = Runs.claim(dctx(ctx.helper), "http://localhost:4000")
      start_and_get(ctx)
      {:ok, scope} = RunTokens.scope(spec.mcp.token)

      assert {:error, text} =
               Pipeline.call_module(
                 CreateTask,
                 %{"project_key" => project.key, "title" => "x"},
                 scope,
                 nil
               )

      assert text =~ "This run can only read the workspace"
      assert Repo.aggregate(Task, :count) == 0
    end
  end

  defp start_and_get(ctx) do
    run = current_run!(ctx.id)
    start!(ctx.helper, run.id)
    reload(run)
  end

  describe "claiming and starting check the conversation (2.2)" do
    test "a discarded conversation: the queued run is cancelled, not claimed (scenario)", ctx do
      run = current_run!(ctx.id)
      # The discard stops the run itself; a claim racing it sees the
      # conversation closed.
      Repo.update_all(from(d in AgentDesign, where: d.id == ^ctx.id), set: [status: :discarded])

      assert claim!(ctx.helper) == []
      assert %Run{status: :cancelled, failure_reason: :obsolete} = reload(run)
    end

    test "another current run at claim time: obsolete", ctx do
      run = current_run!(ctx.id)
      other = run_fixture(ctx.helper, %{status: :succeeded})

      Repo.update_all(from(d in AgentDesign, where: d.id == ^ctx.id),
        set: [current_run_id: other.id]
      )

      assert claim!(ctx.helper) == []
      assert %Run{status: :cancelled, failure_reason: :obsolete} = reload(run)
    end

    test "discarded before starting: failed (obsolete), the daemon aborts", ctx do
      run = current_run!(ctx.id)
      [_] = claim!(ctx.helper)
      Repo.update_all(from(d in AgentDesign, where: d.id == ^ctx.id), set: [status: :discarded])

      assert Runs.starting(dctx(ctx.helper), run.id) == {:ok, {:abort, "obsolete"}}
      assert %Run{status: :failed, failure_reason: :obsolete} = reload(run)
    end

    test "not the current run any more before starting: obsolete", ctx do
      run = current_run!(ctx.id)
      [_] = claim!(ctx.helper)
      Repo.update_all(from(d in AgentDesign, where: d.id == ^ctx.id), set: [current_run_id: nil])

      assert Runs.starting(dctx(ctx.helper), run.id) == {:ok, {:abort, "obsolete"}}
    end

    test "the current turn of an open conversation starts", ctx do
      run = current_run!(ctx.id)
      [_] = claim!(ctx.helper)
      assert Runs.starting(dctx(ctx.helper), run.id) == {:ok, :proceed}
    end
  end

  describe "no automatic retry (2.3)" do
    test "failing with timeout: no retry, a failure message (scenario)", ctx do
      [_] = claim!(ctx.helper)
      run = start_and_get(ctx)
      finish!(ctx.helper, run.id, :failed, %{failure_reason: :timeout})

      refute_enqueued(worker: Retry)
      assert_enqueued(worker: SettleTurn, args: %{run_id: run.id})
      perform_job(SettleTurn, %{run_id: run.id})

      assert List.last(messages!(ctx.id)) |> Map.take([:role, :code, :detail]) ==
               %{role: :system, code: "failed", detail: "timeout"}

      assert design_runs!(ctx.id) |> length() == 1
      assert Repo.aggregate(from(r in Run, where: r.agent_id == ^ctx.helper.id), :count) == 1
    end

    test "lease expired: no new run (scenario)", ctx do
      run = current_run!(ctx.id)
      [_] = claim!(ctx.helper)
      set_run!(run.id, claimed_at: DateTime.add(DateTime.utc_now(), -700, :second))

      perform_job(Sweep, %{})
      assert %Run{status: :failed, failure_reason: :lease_expired} = reload(run)
      refute_enqueued(worker: Retry)
      perform_job(SettleTurn, %{run_id: run.id})

      assert %{code: "failed", detail: "lease_expired"} = List.last(messages!(ctx.id))
      assert Repo.aggregate(from(r in Run, where: r.agent_id == ^ctx.helper.id), :count) == 1
    end

    test "a manual retry: not_retryable (scenario)", ctx do
      run = current_run!(ctx.id)
      end_and_settle!(run, :failed, failure_reason: :cli_error)

      assert Runs.retry(ctx.alice_scope, run.id) == {:error, :not_retryable}
      assert Repo.aggregate(from(r in Run, where: r.agent_id == ^ctx.helper.id), :count) == 1
    end

    test "a task run still retries automatically", ctx do
      project = project_fixture(ctx.alice_scope)
      task = task_fixture(ctx.alice_scope, project.key)

      Repo.update_all(from(p in AgentProfile, where: p.actor_id == ^ctx.helper.id),
        set: [max_concurrency: 4]
      )

      run = running_run!(ctx.helper, %{task_id: task.id})
      finish!(ctx.helper, run.id, :failed, %{failure_reason: :timeout})
      assert_enqueued(worker: Retry, args: %{run_id: run.id})
    end
  end
end
