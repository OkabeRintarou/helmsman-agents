defmodule Helmsman.GitHub.ReconcileSquadTest do
  # add-squads 3.2: the independence of a squad's verification against a
  # fake GitHub (pull-requests "自动合并的前提", decision 11).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentsFixtures
  import Helmsman.PullRequestFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{FakeGitHub, Squads, Tasks}
  alias Helmsman.GitHub.{PullRequest, PullRequests}
  alias Helmsman.GitHub.Workers.ReconcilePR

  @tests %{command: "mix test", passed: true, summary: "ok"}

  setup do
    ctx = pr_fixture()
    fake = FakeGitHub.start()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    runtime_id = profile(ctx.agent).runtime_id

    for name <- ~w(keel/lead keel/lead2 keel/fe keel/review),
        do:
          managed_agent_fixture(ctx.alice_scope, %{
            name: name,
            runtime_id: runtime_id,
            access: "workspace"
          })

    squad_fixture(ctx.alice_scope, %{
      name: "web-team",
      leader: "keel/lead",
      members: [
        %{name: "keel/fe"},
        %{name: "keel/review"},
        %{name: human_actor(ctx.workspace, bob).name}
      ]
    })

    {:ok, _} =
      Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "web-team", start: false})

    fe = agent_actor(ctx.workspace, "keel/fe")

    pushed_run(ctx, sha("5"), sha("0"),
      agent: fe,
      causal_agent_ids: [agent_actor(ctx.workspace, "keel/lead").id, fe.id]
    )

    FakeGitHub.update(fake, &%{&1 | refs: Map.put(&1.refs, ctx.branch, sha("5"))})
    FakeGitHub.put_pull(fake, 1, %{head_ref: ctx.branch, head_sha: sha("5")})
    pr_row(ctx, %{number: 1, head_sha: sha("5")})

    FakeGitHub.update(
      fake,
      &%{&1 | checks: Map.put(&1.checks, sha("5"), [FakeGitHub.check_run("test", "success")])}
    )

    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)
    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :done)
    cancel_pending(ctx.task)
    Repo.delete_all(Oban.Job)

    Map.merge(ctx, %{fake: fake, bob: bob, bob_scope: bob_scope, fe: fe})
  end

  defp reconcile(ctx), do: perform_job(ReconcilePR, %{task_id: ctx.task.id})

  defp current(ctx),
    do:
      Repo.one!(
        from(p in PullRequest, where: p.task_id == ^ctx.task.id, order_by: [desc: p.id], limit: 1)
      )

  defp run_scope(ctx, name) do
    run =
      run_fixture(agent_actor(ctx.workspace, name), %{
        task_id: ctx.task.id,
        status: :running,
        root_initiator_user_id: ctx.alice.id,
        capabilities: ["read", "write_task"]
      })

    {scope, _token} = run_scope_fixture(run)
    {scope, run}
  end

  defp end_run(run),
    do:
      Repo.update_all(from(r in Helmsman.Runs.Run, where: r.id == ^run.id),
        set: [status: :succeeded, finished_at: DateTime.utc_now()]
      )

  defp members(names), do: Enum.map(names, &%{name: &1})

  # alice, outside the squad, re-verifies at the current commit.
  defp reverify_as_alice(ctx) do
    Repo.update_all(from(p in PullRequest, where: p.task_id == ^ctx.task.id),
      set: [merge_status: :stale, merge_reason: :head_changed]
    )

    {:ok, _} = PullRequests.reverify(ctx.alice_scope, ctx.task.ident)
  end

  test "a person outside the squad verifies its work: merged at c5", ctx do
    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :verified)
    assert :ok = reconcile(ctx)
    assert FakeGitHub.get(ctx.fake).last_merge["sha"] == sha("5")
  end

  test "a person member verifies, then leaves the squad: blocked until an outsider re-verifies",
       ctx do
    {:ok, _} = Tasks.transition(ctx.bob_scope, ctx.task.ident, :verified, %{tests: @tests})
    assert :ok = reconcile(ctx)
    assert %PullRequest{merge_status: :blocked, merge_reason: :not_independent} = current(ctx)

    {:ok, _} =
      Squads.update(ctx.alice_scope, "web-team", %{members: members(~w(keel/fe keel/review))})

    assert :ok = reconcile(ctx)

    assert %PullRequest{merge_status: :blocked, merge_note: note} = current(ctx)
    assert note =~ "was on the assignee side (squad web-team) when verifying"
    refute Map.has_key?(FakeGitHub.get(ctx.fake), :last_merge)

    reverify_as_alice(ctx)
    assert :ok = reconcile(ctx)
    assert FakeGitHub.get(ctx.fake).last_merge["sha"] == sha("5")
  end

  test "the review agent verifies, then leaves the squad: still blocked", ctx do
    {scope, run} = run_scope(ctx, "keel/review")
    {:ok, _} = Tasks.transition(scope, ctx.task.ident, :verified, %{tests: @tests})
    end_run(run)

    {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{members: members(~w(keel/fe))})
    assert :ok = reconcile(ctx)
    assert %PullRequest{merge_status: :blocked, merge_reason: :not_independent} = current(ctx)
    refute Map.has_key?(FakeGitHub.get(ctx.fake), :last_merge)
  end

  test "the leader verifies, then is replaced: still blocked", ctx do
    {scope, run} = run_scope(ctx, "keel/lead")
    {:ok, _} = Tasks.transition(scope, ctx.task.ident, :verified, %{tests: @tests})
    end_run(run)

    {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/lead2"})
    assert :ok = reconcile(ctx)
    assert %PullRequest{merge_status: :blocked, merge_reason: :not_independent} = current(ctx)

    reverify_as_alice(ctx)
    assert :ok = reconcile(ctx)
    assert FakeGitHub.get(ctx.fake).last_merge["sha"] == sha("5")
  end
end
