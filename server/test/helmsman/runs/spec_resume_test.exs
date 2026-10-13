defmodule Helmsman.Runs.SpecResumeTest do
  # #52 task 3.1: drive session history through the domain's claim/report API.
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, Runs, Tx}
  alias Helmsman.Runs.{Origin, Run}
  alias HelmsmanProtocol.{Event, Report}

  @instructions "You are the backend dev."
  @base_url "https://hm.test"

  setup do
    ctx = dispatch_fixture(%{instructions: @instructions})
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.merge(ctx, %{task: task, dctx: daemon_ctx(daemon_of(ctx.agent))})
  end

  test "resume a session confirmed in the finished report with only the trigger prompt", ctx do
    first = claim(ctx)
    start(ctx, first)
    finish(ctx, first, %{session_id: "s-1"})

    next = claim(ctx)
    assert next.resume_session_id == "s-1"
    assert next.prompt == trigger_prompt(ctx)
  end

  test "context overflow prevents falling back to an older confirmed session", ctx do
    establish_session(ctx)
    overflow = claim(ctx)
    start(ctx, overflow)

    finish(ctx, overflow, %{status: :failed, failure_reason: :context_overflow, session_id: "s-1"})

    assert_full_prompt(ctx, claim(ctx))
  end

  test "failed resume ignores an old daemon's started candidate and opens a new session", ctx do
    establish_session(ctx)
    failed = claim(ctx)
    assert failed.resume_session_id == "s-1"
    start(ctx, failed, "s-1")
    assert Repo.get!(Run, failed.run_id).session_id == nil
    finish(ctx, failed, %{status: :failed, failure_reason: :cli_error, session_id: nil})
    assert Repo.get!(Run, failed.run_id).session_id == nil

    assert_full_prompt(ctx, claim(ctx))
  end

  test "successful resume records the session event despite an empty finished session", ctx do
    establish_session(ctx)
    resumed = claim(ctx)
    start(ctx, resumed, "s-1")

    {:ok, event} =
      Event.new(%{
        seq: 1,
        type: :session,
        data: %{session_id: "s-1"},
        at: DateTime.utc_now()
      })

    assert Runs.append_events(ctx.dctx, resumed.run_id, [event]) == {:ok, 1}
    finish(ctx, resumed, %{session_id: nil})
    assert Repo.get!(Run, resumed.run_id).session_id == "s-1"
    assert claim(ctx).resume_session_id == "s-1"
  end

  test "preparation failure does not hide the previous confirmed session", ctx do
    establish_session(ctx)
    failed = claim(ctx)
    finish(ctx, failed, %{status: :failed, failure_reason: :workspace_prepare})
    assert Repo.get!(Run, failed.run_id).started_at == nil
    assert claim(ctx).resume_session_id == "s-1"
  end

  test "a CLI that ends without confirming a session opens a new session next time", ctx do
    establish_session(ctx)
    empty = claim(ctx)
    start(ctx, empty)
    finish(ctx, empty, %{session_id: nil})

    assert_full_prompt(ctx, claim(ctx))
  end

  test "sessions are scoped to the same task", ctx do
    establish_session(ctx)
    other_task = task_fixture(ctx.alice_scope, ctx.project.key)
    assert_full_prompt(%{ctx | task: other_task}, claim(%{ctx | task: other_task}))
  end

  test "sessions are scoped to the same agent", ctx do
    establish_session(ctx)

    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/other",
      runtime_id: profile(ctx.agent).runtime_id,
      instructions: @instructions
    })

    other_agent = agent_actor(ctx.workspace, "keel/other")
    other_ctx = %{ctx | agent: other_agent}
    assert_full_prompt(other_ctx, claim(other_ctx))
  end

  test "sessions are scoped to the same runtime", ctx do
    establish_session(ctx)
    # Rebind via the domain API; the original runtime's history remains intact.
    {daemon, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
    runtime = runtime_fixture(ctx.workspace, daemon)
    assert {:ok, _} = Agents.update(ctx.alice_scope, ctx.agent.name, %{runtime_id: runtime.id})
    rebound = %{ctx | dctx: daemon_ctx(daemon)}
    assert_full_prompt(rebound, claim(rebound))
  end

  defp claim(ctx) do
    assert {:ok, %{result: :queued}} =
             Tx.run(fn ->
               Runs.enqueue(
                 Origin.from_scope(ctx.alice_scope),
                 %{agent: ctx.agent, profile: profile(ctx.agent), task: ctx.task},
                 %{kind: :manual, instructions: nil}
               )
             end)

    assert {:ok, descriptions} = Runs.claim(ctx.dctx, @base_url)

    Enum.find(
      descriptions,
      &(&1.agent.name == ctx.agent.name and &1.task.ident == ctx.task.ident)
    ) ||
      flunk("run was not claimed")
  end

  defp start(ctx, description, candidate \\ nil) do
    assert Runs.starting(ctx.dctx, description.run_id) == {:ok, :proceed}

    assert Runs.started(ctx.dctx, %Report.Started{
             run_id: description.run_id,
             session_id: candidate
           }) == :ok
  end

  defp finish(ctx, description, attrs) do
    {:ok, report} =
      Report.Finished.new(Map.merge(%{run_id: description.run_id, status: :succeeded}, attrs))

    assert Runs.finish(ctx.dctx, report) == :ok
  end

  defp establish_session(ctx) do
    first = claim(ctx)
    start(ctx, first)
    finish(ctx, first, %{session_id: "s-1"})
  end

  defp assert_full_prompt(ctx, description) do
    assert description.resume_session_id == nil
    assert String.starts_with?(description.prompt, @instructions)
    assert description.prompt =~ "You may only change #{ctx.task.ident}."
    assert description.prompt =~ "get_task(\"#{ctx.task.ident}\")"
  end

  defp trigger_prompt(ctx) do
    "Why you were started:\n- #{ctx.alice_scope.actor.name} started you manually.\n" <>
      "Before you start, call get_task(\"#{ctx.task.ident}\") to read the full " <>
      "requirements, history and feedback."
  end
end
