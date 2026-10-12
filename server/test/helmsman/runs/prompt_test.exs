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

  describe "with a repository (add-daemon-git-workspace 1.3)" do
    setup ctx do
      repository = %Helmsman.GitHub.Repository{id: 1, github_id: 4711, owner: "acme", name: "app"}
      branch = "hm/#{ctx.workspace.id}/#{String.downcase(ctx.task.ident)}"

      repo = %{
        repository: repository,
        base_branch: "main",
        branch: branch,
        rescue_branches: [],
        token: %{token: "ghs_secret_push_token", expires_at: DateTime.utc_now()}
      }

      %{repo: repo, branch: branch}
    end

    defp build_repo(run, repo), do: Spec.build(run, @token, "https://hm.test", repo)

    defp reopen(ctx, reason),
      do: trigger("reopen", ctx.workspace, ctx.alice, ctx.agent, %{"reason" => reason})

    test "the prompt with a repository (scenario)", ctx do
      repo = %{ctx.repo | rescue_branches: ["#{ctx.branch}-run-31"]}
      run = claimed(ctx, %{triggers: [assign(ctx)]})
      assert {:ok, %RunSpec{prompt: prompt, repo: spec_repo}} = build_repo(run, repo)

      assert prompt =~
               "\nWorking directory: a git worktree of acme/app on branch #{ctx.branch} " <>
                 "(based on main). Commit your changes, but do not push, open pull requests, " <>
                 "or switch branches; Helmsman does that.\n" <>
                 "Before this run Helmsman merged #{ctx.branch}-run-31 into #{ctx.branch}.\n" <>
                 "If `git status` shows unmerged paths, resolve the conflicts and commit them " <>
                 "before anything else.\n" <>
                 "Before you start, call get_task(\"#{ctx.task.ident}\")"

      refute prompt =~ "no repository"
      refute prompt =~ "ghs_secret_push_token"
      refute prompt =~ @token
      assert spec_repo.git_token == "ghs_secret_push_token"
      assert spec_repo.github_repository_id == 4711
      refute inspect(spec_repo) =~ "ghs_secret_push_token"
    end

    test "no merge line without rescue branches or a merge conflict reopen", ctx do
      run = claimed(ctx, %{triggers: [assign(ctx), reopen(ctx, "rejected")]})
      assert {:ok, %RunSpec{prompt: prompt}} = build_repo(run, ctx.repo)
      refute prompt =~ "Helmsman merged"
      assert prompt =~ "If `git status` shows unmerged paths"
    end

    test "a merge conflict reopen mentions origin/<base branch>", ctx do
      repo = %{ctx.repo | rescue_branches: ["#{ctx.branch}-run-31"]}
      run = claimed(ctx, %{triggers: [assign(ctx), reopen(ctx, "merge_conflict")]})
      assert {:ok, %RunSpec{prompt: prompt, trigger: trigger}} = build_repo(run, repo)
      assert trigger.reason == "merge_conflict"

      assert prompt =~
               "Before this run Helmsman merged #{ctx.branch}-run-31, origin/main into #{ctx.branch}.\n"

      run = claimed(ctx, %{triggers: [reopen(ctx, "merge_conflict")]})
      assert {:ok, %RunSpec{prompt: prompt}} = build_repo(run, ctx.repo)
      assert prompt =~ "Before this run Helmsman merged origin/main into #{ctx.branch}.\n"
    end

    test "a resumed session: why, the merge line, the conflicts line", ctx do
      run_fixture(ctx.agent, %{
        task_id: ctx.task.id,
        status: :succeeded,
        session_id: "s-1",
        finished_at: DateTime.utc_now()
      })

      manual = trigger("manual", ctx.workspace, ctx.alice, ctx.agent)
      repo = %{ctx.repo | rescue_branches: ["#{ctx.branch}-run-31"]}
      assert {:ok, spec} = build_repo(claimed(ctx, %{triggers: [manual]}), repo)
      assert spec.resume_session_id == "s-1"

      assert spec.prompt ==
               "Why you were started:\n- #{ctx.alice_actor.name} started you manually.\n" <>
                 "Before this run Helmsman merged #{ctx.branch}-run-31 into #{ctx.branch}.\n" <>
                 "If `git status` shows unmerged paths, resolve the conflicts and commit them " <>
                 "before anything else.\n" <>
                 "Before you start, call get_task(\"#{ctx.task.ident}\") to read the full " <>
                 "requirements, history and feedback."

      refute spec.prompt =~ "ghs_secret_push_token"

      assert {:ok, spec} = build_repo(claimed(ctx, %{triggers: [manual]}), ctx.repo)
      refute spec.prompt =~ "Helmsman merged"
      assert spec.prompt =~ "If `git status` shows unmerged paths"
    end
  end
end
