defmodule Helmsman.Runs.PromptTest do
  # add-run-lifecycle 2.4: the run description and the prompt (decisions
  # 9–11).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Runs.{Run, Spec}
  alias HelmsmanProtocol.RunSpec

  @token "hmr_" <> String.duplicate("a", 52)

  setup do
    ctx = dispatch_fixture()

    profile =
      ctx.agent
      |> profile()
      |> Ecto.Changeset.change(
        instructions: "You are the backend dev.",
        env: %{"API_KEY" => "very-secret-value"},
        extra_mcp_servers: %{"docs" => %{"url" => "https://docs.invalid/secret-mcp"}},
        custom_args: ["--verbose"],
        model: "opus",
        timeout_minutes: 30,
        idle_timeout_minutes: 5
      )
      |> Repo.update!()

    task =
      task_fixture(ctx.alice_scope, ctx.project.key, %{
        title: "Add login",
        description: "SECRET DESCRIPTION BODY"
      })

    alice = human_actor(ctx.workspace, ctx.alice)
    Map.merge(ctx, %{profile: profile, task: task, alice_actor: alice})
  end

  defp claimed(ctx, attrs) do
    run_fixture(ctx.agent, Map.merge(%{status: :claimed, task_id: ctx.task.id}, attrs))
  end

  defp build(run), do: Spec.build(run, @token, "https://hm.test")

  defp assign(ctx), do: trigger("assign", ctx.workspace, ctx.alice, ctx.agent)

  test "the full prompt (scenario)", ctx do
    run = claimed(ctx, %{triggers: [assign(ctx)]})
    assert {:ok, %RunSpec{prompt: prompt} = spec} = build(run)

    ident = ctx.task.ident
    key = ctx.project.key

    assert prompt ==
             """
             You are the backend dev.

             ---
             You are the agent "keel/dev" in the Helmsman workspace "#{ctx.workspace.slug}". The Helmsman MCP server (named helmsman) is already configured and your identity is fixed; do not call identify.
             Follow the collaboration rules in the MCP resource helmsman://workflow.
             You may only change #{ident}.

             This run: task #{ident} (project #{key}): Add login
             Why you were started:
             - #{ctx.alice_actor.name} assigned #{ident} to you.
             Working directory: an empty scratch directory that is kept for later runs on #{ident}. This project has no repository.
             Before you start, call get_task("#{ident}") to read the full requirements, history and feedback.\
             """

    refute prompt =~ "SECRET DESCRIPTION BODY"
    refute prompt =~ "hmr_"
    assert spec.resume_session_id == nil
    assert spec.task == %RunSpec.Task{ident: ident, title: "Add login"}
  end

  test "the description: agent, MCP, limits, no repository, secrets hidden", ctx do
    run = claimed(ctx, %{triggers: [assign(ctx)]})
    assert {:ok, spec} = build(run)

    assert spec.run_id == run.id
    assert spec.workspace == %RunSpec.Workspace{id: ctx.workspace.id, slug: ctx.workspace.slug}
    assert %RunSpec.Agent{name: "keel/dev", provider: :claude, model: "opus"} = spec.agent
    assert spec.agent.custom_args == ["--verbose"]
    assert spec.agent.env == %{"API_KEY" => "very-secret-value"}
    assert spec.mcp == %RunSpec.MCP{url: "https://hm.test/mcp", token: @token}
    assert spec.limits == %RunSpec.Limits{timeout_ms: 1_800_000, idle_timeout_ms: 300_000}
    assert spec.repo == nil
    assert spec.trigger == %RunSpec.Trigger{kind: "assign", reason: nil, feedback_id: nil}

    text = inspect(spec)
    refute text =~ "very-secret-value"
    refute text =~ "secret-mcp"
    refute text =~ @token
  end

  test "resuming a session sends only why it was started (scenario)", ctx do
    run_fixture(ctx.agent, %{
      task_id: ctx.task.id,
      status: :succeeded,
      session_id: "s-1",
      finished_at: DateTime.utc_now()
    })

    manual = trigger("manual", ctx.workspace, ctx.alice, ctx.agent)
    assert {:ok, spec} = build(claimed(ctx, %{triggers: [manual]}))
    assert spec.resume_session_id == "s-1"

    assert spec.prompt ==
             "Why you were started:\n- #{ctx.alice_actor.name} started you manually.\n" <>
               "Before you start, call get_task(\"#{ctx.task.ident}\") to read the full " <>
               "requirements, history and feedback."
  end

  test "no resume after a context overflow (scenario), on another runtime or another task",
       ctx do
    previous = fn attrs ->
      run_fixture(
        ctx.agent,
        Map.merge(
          %{
            task_id: ctx.task.id,
            status: :failed,
            session_id: "s-1",
            finished_at: DateTime.utc_now()
          },
          attrs
        )
      )
    end

    previous.(%{failure_reason: :context_overflow})

    assert {:ok, %{resume_session_id: nil, prompt: "You are the backend dev." <> _}} =
             build(claimed(ctx, %{triggers: [assign(ctx)]}))

    other_task = task_fixture(ctx.alice_scope, ctx.project.key)
    run_fixture(ctx.agent, %{task_id: other_task.id, status: :succeeded, session_id: "s-2"})
    run = claimed(ctx, %{task_id: other_task.id, triggers: [assign(ctx)]})

    Repo.update_all(from(r in Run, where: r.session_id == "s-2"),
      set: [runtime_id: run.runtime_id]
    )

    assert {:ok, %{resume_session_id: "s-2"}} = build(run)

    # A newer ended run with a session wins over the overflowed one.
    previous.(%{failure_reason: :timeout, session_id: "s-3"})
    assert {:ok, %{resume_session_id: "s-3"}} = build(claimed(ctx, %{triggers: [assign(ctx)]}))
  end

  test "no task, no instructions", ctx do
    ctx.profile |> Ecto.Changeset.change(instructions: "") |> Repo.update!()

    manual =
      trigger("manual", ctx.workspace, ctx.alice, ctx.agent, %{
        "instructions" => "Summarize the week.\nKeep it short."
      })

    run = run_fixture(ctx.agent, %{status: :claimed, triggers: [manual]})
    assert {:ok, spec} = build(run)
    assert spec.task == nil
    assert spec.resume_session_id == nil
    name = ctx.alice_actor.name

    assert spec.prompt ==
             """
             You are the agent "keel/dev" in the Helmsman workspace "#{ctx.workspace.slug}". The Helmsman MCP server (named helmsman) is already configured and your identity is fixed; do not call identify.
             Follow the collaboration rules in the MCP resource helmsman://workflow.
             You may read the workspace but you cannot change any task in this run.

             This run has no task.
             Why you were started:
             - #{name} started you manually.
             Instructions from #{name}:
             > Summarize the week.
             > Keep it short.
             Working directory: an empty scratch directory for this run only.\
             """
  end

  test "retry lines and the main trigger", ctx do
    failed =
      run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :failed, failure_reason: :timeout})

    auto = %{"kind" => "retry", "retry_of" => failed.id, "auto" => true, "by_actor_id" => nil}

    manual_retry = %{
      "kind" => "retry",
      "retry_of" => failed.id,
      "auto" => false,
      "by_actor_id" => ctx.alice_actor.id
    }

    run = claimed(ctx, %{attempt: 2, triggers: [auto, assign(ctx), manual_retry]})
    assert {:ok, spec} = build(run)
    assert spec.prompt =~ "- This is retry 2 after run #{failed.id} failed: timeout.\n"
    assert spec.prompt =~ "- #{ctx.alice_actor.name} retried run #{failed.id}.\n"
    assert spec.trigger.kind == "assign"

    assert Spec.main_trigger([auto]).kind == "retry"

    reopen = %{"kind" => "reopen", "reason" => "merge_conflict", "feedback_id" => 4}

    assert Spec.main_trigger([assign(ctx), reopen]) ==
             %{kind: "reopen", reason: "merge_conflict", feedback_id: 4}
  end
end
