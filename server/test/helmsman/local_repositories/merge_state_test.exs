defmodule Helmsman.LocalRepositories.MergeStateTest do
  # add-local-repositories 2.5: the task branch and its merge state
  # (decision 9) and the join reply's watch list (decision 13).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentsFixtures
  import Helmsman.GitRunFixtures, only: [sha: 1]
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Daemons, Events, LocalRepositories, Members, Projects, Runs, Tasks}
  alias Helmsman.Daemons.Daemon
  alias Helmsman.LocalRepositories.{TaskLocalBranch, Workers.RecordBranch}
  alias Helmsman.Workspaces.Membership
  alias HelmsmanProtocol.Report

  setup do
    ctx = local_run_fixture()
    :ok = Events.subscribe(Events.topic(:task, ctx.task.id))
    ctx
  end

  # Run `id` pushed `head` to the task branch (its record is written, the
  # branch job is not run yet).
  defp push(ctx, run, head) do
    assert :ok =
             Runs.pushed(ctx.dctx, %Report.Pushed{
               run_id: run.id,
               branch: ctx.branch,
               base_sha: sha("0"),
               head_sha: head,
               commits: [%Report.Pushed.Commit{sha: head, subject: "Work"}],
               rescue_branch: nil
             })
  end

  defp record(run), do: perform_job(RecordBranch, %{run_id: run.id})

  defp delivered(ctx, head) do
    run = local_run(ctx)
    push(ctx, run, head)
    assert :ok = record(run)
    run
  end

  defp status(ctx, head, merged, attrs \\ %{}) do
    Map.merge(
      %Report.RepoStatus{
        workspace_id: ctx.workspace.id,
        name: "app",
        results: [%Report.RepoStatus.Result{branch: ctx.branch, head_sha: head, merged: merged}]
      },
      attrs
    )
  end

  test "merged by the user, detected by the daemon (scenario)", ctx do
    delivered(ctx, sha("c"))
    assert_receive {:local_branch_changed, _}

    assert %TaskLocalBranch{state: "open", head_sha: head, branch: branch} =
             local_branch(ctx.task.id)

    assert {head, branch} == {sha("c"), ctx.branch}

    assert :ok = LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("c"), :no))
    assert %TaskLocalBranch{state: "open"} = local_branch(ctx.task.id)
    assert LocalRepositories.merged?(ctx.task.id) == false

    assert :ok = LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("c"), :yes))
    ident = ctx.task.ident
    assert_receive {:local_branch_changed, ^ident}

    assert %TaskLocalBranch{state: "merged", merged_at: %DateTime{}, merged_by_id: nil} =
             local_branch(ctx.task.id)

    assert LocalRepositories.merged?(ctx.task.id)
  end

  test "标记时已有新交付: expected_head_sha is checked under the row lock", ctx do
    delivered(ctx, sha("1"))
    delivered(ctx, sha("2"))

    assert {:error, {:head_changed, head}} =
             LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident, "ok",
               expected_head_sha: sha("1")
             )

    assert head == sha("2")
    assert %TaskLocalBranch{state: "open", merge_note: nil} = local_branch(ctx.task.id)

    assert {:ok, %{state: "merged", head_sha: ^head}} =
             LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident, nil,
               expected_head_sha: head
             )
  end

  test "the branch view: effective base branch and last change", ctx do
    delivered(ctx, sha("1"))
    row = local_branch(ctx.task.id)

    assert {:ok, %{base_branch: "main", updated_at: updated_at}} =
             LocalRepositories.get_branch(ctx.alice_scope, ctx.task.ident)

    assert updated_at == row.updated_at

    {:ok, _} =
      Projects.bind_local_repository(ctx.alice_scope, ctx.project.key, ctx.local_repo.id,
        base_branch: "develop"
      )

    assert {:ok, %{base_branch: "develop"}} =
             LocalRepositories.get_branch(ctx.alice_scope, ctx.task.ident)

    assert {:ok, %{base_branch: "develop", updated_at: %DateTime{}}} =
             LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident)
  end

  test "squash merged, marked by a person with a note (scenario)", ctx do
    delivered(ctx, sha("c"))
    assert :ok = LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("c"), :no))
    assert :ok = LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("c"), :unknown))

    assert {:ok, %{state: "merged", merge_note: "squashed into main", merged_by: by}} =
             LocalRepositories.mark_merged(
               ctx.alice_scope,
               ctx.task.ident,
               " squashed into main "
             )

    assert by.kind == :human
    assert %TaskLocalBranch{merged_by_id: id} = local_branch(ctx.task.id)
    assert id == ctx.alice_scope.actor.id

    assert {:error, {:invalid_state, "merged"}} =
             LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident)

    assert {:ok, %{state: "open", merge_note: nil, merged_by: nil}} =
             LocalRepositories.mark_unmerged(ctx.alice_scope, ctx.task.ident)

    assert {:error, {:invalid_state, "open"}} =
             LocalRepositories.mark_unmerged(ctx.alice_scope, ctx.task.ident)
  end

  test "manual_only: a detected merge is not undone, a person's mark is", ctx do
    delivered(ctx, sha("c"))
    assert :ok = LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("c"), :yes))
    assert %TaskLocalBranch{state: "merged", merged_by_id: nil} = local_branch(ctx.task.id)

    assert {:error, :not_manual} =
             LocalRepositories.mark_unmerged(ctx.alice_scope, ctx.task.ident, manual_only: true)

    assert %TaskLocalBranch{state: "merged", merged_by_id: nil, merged_at: %DateTime{}} =
             local_branch(ctx.task.id)

    # Without the option the existing behaviour is kept.
    assert {:ok, %{state: "open"}} =
             LocalRepositories.mark_unmerged(ctx.alice_scope, ctx.task.ident)

    assert {:ok, %{state: "merged"}} =
             LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident, "manual")

    assert {:ok, %{state: "open"}} =
             LocalRepositories.mark_unmerged(ctx.alice_scope, ctx.task.ident, manual_only: true)

    assert {:error, {:invalid_state, "open"}} =
             LocalRepositories.mark_unmerged(ctx.alice_scope, ctx.task.ident, manual_only: true)
  end

  test "an agent cannot mark (scenario); a viewer cannot either", ctx do
    run = delivered(ctx, sha("c"))
    {agent_scope, _token} = run_scope_fixture(run)

    assert {:error, :forbidden} = LocalRepositories.mark_merged(agent_scope, ctx.task.ident)
    assert {:error, :forbidden} = LocalRepositories.mark_unmerged(agent_scope, ctx.task.ident)

    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    assert {:error, :forbidden} = LocalRepositories.mark_merged(viewer_scope, ctx.task.ident)
    assert %TaskLocalBranch{state: "open"} = local_branch(ctx.task.id)
  end

  for order <- [:newer_first, :older_first] do
    test "a late push result of an older delivery (scenario, jobs #{order})", ctx do
      claimed = DateTime.utc_now()
      ended = %{status: :succeeded, finished_at: DateTime.utc_now()}
      run40 = local_run(ctx, Map.put(ended, :claimed_at, DateTime.add(claimed, -60)))
      run41 = local_run(ctx, Map.put(ended, :claimed_at, claimed))

      # Run 41's C2 is recorded first, run 40's C1 arrives after it.
      push(ctx, run41, sha("2"))
      push(ctx, run40, sha("1"))

      jobs = if unquote(order) == :newer_first, do: [run41, run40], else: [run40, run41]
      Enum.each(jobs, &assert(:ok = record(&1)))
      assert %TaskLocalBranch{state: "open", head_sha: head} = local_branch(ctx.task.id)
      assert head == sha("2")

      # Merged at C2, then both jobs again: nothing goes back.
      assert :ok = LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("2"), :yes))
      Enum.each(jobs, &assert(:ok = record(&1)))
      assert %TaskLocalBranch{state: "merged", head_sha: head} = local_branch(ctx.task.id)
      assert head == sha("2")

      assert {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)
      assert {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :done)
      {_bob, reviewer} = member_scope_fixture(ctx.workspace, :member)
      assert {:ok, _task} = Tasks.transition(reviewer, ctx.task.ident, :verified)

      assert Repo.one!(
               from(e in Helmsman.Tasks.TaskEvent,
                 where: e.task_id == ^ctx.task.id and e.to_status == :verified,
                 select: e.verified_sha
               )
             ) == sha("2")
    end
  end

  test "an outdated report is ignored (scenario)", ctx do
    delivered(ctx, sha("a"))
    delivered(ctx, sha("b"))

    assert :ok = LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("a"), :yes))
    assert %TaskLocalBranch{state: "open", head_sha: head} = local_branch(ctx.task.id)
    assert head == sha("b")
  end

  test "a record reported for an inherited run does not change the latest delivery", ctx do
    earlier =
      local_run(ctx, %{claimed_at: DateTime.add(DateTime.utc_now(), -60), status: :failed})

    delivered(ctx, sha("2"))
    assert :ok = LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("2"), :yes))

    # The later run reports the push on behalf of the run it inherited.
    push(ctx, earlier, sha("2"))
    assert :ok = record(earlier)
    assert %TaskLocalBranch{state: "merged", head_sha: head} = local_branch(ctx.task.id)
    assert head == sha("2")
  end

  test "a push to a rescue branch does not update the head", ctx do
    delivered(ctx, sha("a"))
    run = local_run(ctx)

    assert :ok =
             Runs.pushed(ctx.dctx, %Report.Pushed{
               run_id: run.id,
               branch: ctx.branch,
               base_sha: sha("0"),
               head_sha: sha("e"),
               commits: [],
               rescue_branch: "#{ctx.branch}-run-#{run.id}"
             })

    assert :ok = record(run)
    assert local_branch(ctx.task.id).head_sha == sha("a")
  end

  test "a new delivery after merged goes back to open", ctx do
    delivered(ctx, sha("a"))

    {:ok, _} = LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident, "done")
    delivered(ctx, sha("b"))

    assert %TaskLocalBranch{
             state: "open",
             head_sha: head,
             merged_at: nil,
             merged_by_id: nil,
             merge_note: nil
           } = local_branch(ctx.task.id)

    assert head == sha("b")
  end

  test "repo_status of another daemon or an old authorization", ctx do
    delivered(ctx, sha("a"))
    {other, _} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})

    assert {:error, :not_found} =
             LocalRepositories.apply_status(daemon_ctx(other), status(ctx, sha("a"), :yes))

    assert {:error, :not_found} =
             LocalRepositories.apply_status(
               ctx.dctx,
               status(ctx, sha("a"), :yes, %{name: "nope"})
             )

    {:ok, _} = Daemons.rotate_token(ctx.daemon.id, ctx.daemon.auth_epoch)
    old = %{ctx.dctx | auth_epoch: ctx.daemon.auth_epoch - 1}

    assert {:error, :reauthorized} =
             LocalRepositories.apply_status(old, status(ctx, sha("a"), :yes))

    assert local_branch(ctx.task.id).state == "open"
  end

  test "repo_status after the daemon stops serving the workspace is refused", ctx do
    delivered(ctx, sha("a"))
    assert_receive {:local_branch_changed, _}
    {:ok, _} = Daemons.set_workspaces(ctx.alice_scope, ctx.daemon.id, [])

    assert {:error, :not_found} =
             LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("a"), :yes))

    assert local_branch(ctx.task.id).state == "open"
    refute_receive {:local_branch_changed, _}
  end

  test "repo_status after the machine owner is no longer a member is refused", ctx do
    delivered(ctx, sha("a"))
    assert_receive {:local_branch_changed, _}
    {_bob, bob_scope} = member_scope_fixture(ctx.workspace, :owner)

    membership =
      Repo.get_by!(Membership, workspace_id: ctx.workspace.id, user_id: ctx.alice.id)

    {:ok, _} = Members.change_role(bob_scope, membership.id, :viewer)

    assert {:error, :not_found} =
             LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("a"), :yes))

    {:ok, _} = Members.remove(bob_scope, membership.id)

    assert {:error, _} =
             LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("a"), :yes))

    assert local_branch(ctx.task.id).state == "open"
    refute_receive {:local_branch_changed, _}
  end

  test "service or authorization lost between the first check and the write", ctx do
    delivered(ctx, sha("a"))
    assert_receive {:local_branch_changed, _}

    hook = fn revoke ->
      Process.put(:helmsman_test_hook, fn
        :repo_status_checked ->
          Process.delete(:helmsman_test_hook)
          revoke.()

        _point ->
          :ok
      end)
    end

    # A new authorization of the machine (a new join) bumps the epoch.
    hook.(fn ->
      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), inc: [auth_epoch: 1])
    end)

    assert {:error, :reauthorized} =
             LocalRepositories.apply_status(ctx.dctx, status(ctx, sha("a"), :yes))

    dctx = daemon_ctx(Repo.reload!(ctx.daemon))
    hook.(fn -> {:ok, _} = Daemons.set_workspaces(ctx.alice_scope, ctx.daemon.id, []) end)

    assert {:error, :not_found} =
             LocalRepositories.apply_status(dctx, status(ctx, sha("a"), :yes))

    assert local_branch(ctx.task.id).state == "open"
    refute_receive {:local_branch_changed, _}

    # A report written before the revocation stays.
    {:ok, _} =
      Daemons.set_workspaces(ctx.alice_scope, ctx.daemon.id, [ctx.workspace.id])

    assert :ok = LocalRepositories.apply_status(dctx, status(ctx, sha("a"), :yes))
    {:ok, _} = Daemons.set_workspaces(ctx.alice_scope, ctx.daemon.id, [])
    assert local_branch(ctx.task.id).state == "merged"
  end

  test "run and agent scopes never see the path, even on their user's machine", ctx do
    delivered(ctx, sha("a"))
    {run_scope, _token} = run_scope_fixture(local_run(ctx))
    agent_scope = %{ctx.alice_scope | actor: ctx.agent}

    for scope <- [run_scope, agent_scope] do
      assert scope.user.id == ctx.alice.id
      assert {:ok, [%{name: "app", path: nil}]} = LocalRepositories.list(scope)

      assert {:ok, %{local_repository: %{name: "app", path: nil}}} =
               LocalRepositories.get_branch(scope, ctx.task.ident)

      assert {:ok, %{local_repository: %{name: "app", path: nil}}} =
               Projects.get(scope, ctx.project.key)
    end

    assert {:ok, [%{path: "/" <> _}]} = LocalRepositories.list(ctx.alice_scope)
  end

  test "refresh and a recorded local push send config_changed to the daemon", ctx do
    :ok = Events.subscribe(Events.topic(:daemon, ctx.daemon.id))
    delivered(ctx, sha("a"))
    assert_receive {:daemon_config_changed}

    assert :ok = LocalRepositories.refresh(ctx.alice_scope, ctx.task.ident)
    assert_receive {:daemon_config_changed}

    other = Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, ctx.project.key)
    assert {:error, :not_found} = LocalRepositories.refresh(ctx.alice_scope, other.ident)
  end

  test "the join reply watches open branches only, at most 500", ctx do
    delivered(ctx, sha("a"))

    assert [%{name: "app", local_repository_id: id, watch: [watch]}] =
             LocalRepositories.reply_entries(ctx.daemon.id)

    assert id == ctx.local_repo.id
    assert %{branch: branch, head_sha: head, base_branch: "main"} = watch
    assert {branch, head} == {ctx.branch, sha("a")}

    {:ok, _} = LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident)
    assert [%{watch: []}] = LocalRepositories.reply_entries(ctx.daemon.id)

    many_open_branches(ctx, 501)
    assert [%{watch: watch}] = LocalRepositories.reply_entries(ctx.daemon.id)
    assert length(watch) == 500
  end

  # Copies the fixture's task 501 times and gives each an open branch.
  defp many_open_branches(ctx, count) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = 'tasks' AND column_name NOT IN ('id', 'ident', 'seq')"
      )

    columns = Enum.map_join(rows, ", ", fn [name] -> ~s("#{name}") end)

    Repo.query!(
      "INSERT INTO tasks (#{columns}, ident, seq) " <>
        "SELECT #{columns}, $2 || '-' || (10000 + g), 10000 + g FROM tasks, " <>
        "generate_series(1, $3::int) AS g WHERE id = $1",
      [ctx.task.id, ctx.project.key, count]
    )

    Repo.query!(
      "INSERT INTO task_local_branches " <>
        "(workspace_id, task_id, local_repository_id, branch, head_sha, state, inserted_at, updated_at) " <>
        "SELECT workspace_id, id, $2, 'hm/x-' || id, 'abc', 'open', now(), now() FROM tasks " <>
        "WHERE project_id = $1 AND seq > 10000",
      [ctx.project.id, ctx.local_repo.id]
    )
  end
end
