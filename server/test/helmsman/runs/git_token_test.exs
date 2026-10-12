defmodule Helmsman.Runs.GitTokenTest do
  # add-daemon-git-workspace 1.4: renewing a push token (decision 4).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.GitRunFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Runs

  setup do
    git_run_fixture()
  end

  test "a running run gets a new token without a transaction around the call", ctx do
    stub_push_tokens()

    assert {:ok, %{token: "ghs_push_1", expires_at: %DateTime{}}} =
             Runs.git_token(ctx.dctx, ctx.run.id)

    assert_received {:push_token_request, _id, %{"repository_ids" => [github_id]}}
    assert github_id == ctx.repository.github_id
    refute_received :http_in_transaction
  end

  test "claimed and cancelling runs get one too", ctx do
    stub_push_tokens()

    for status <- [:claimed, :cancelling] do
      set_run(ctx.run, status: status)
      assert {:ok, %{token: _}} = Runs.git_token(ctx.dctx, ctx.run.id)
    end
  end

  test "late wrap-up (scenario): failed runtime_offline 10 minutes ago", ctx do
    stub_push_tokens()

    set_run(ctx.run,
      status: :failed,
      failure_reason: :runtime_offline,
      finished_at: DateTime.add(DateTime.utc_now(), -600, :second)
    )

    assert {:ok, %{token: "ghs_push_1"}} = Runs.git_token(ctx.dctx, ctx.run.id)
  end

  test "past the window (scenario): ended 31 minutes ago is wrong_state", ctx do
    counter = stub_push_tokens()

    set_run(ctx.run,
      status: :succeeded,
      finished_at: DateTime.add(DateTime.utc_now(), -31 * 60, :second)
    )

    assert Runs.git_token(ctx.dctx, ctx.run.id) == {:error, :wrong_state}
    assert :counters.get(counter, 1) == 0
  end

  test "another daemon's run, a run without a repository, a queued run: not_found", ctx do
    stub_push_tokens()
    {other, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
    assert Runs.git_token(daemon_ctx(other), ctx.run.id) == {:error, :not_found}

    plain = claimed_git_run(ctx, %{task_id: nil, repository_id: nil, branch: nil})
    assert Runs.git_token(ctx.dctx, plain.id) == {:error, :not_found}

    queued = run_fixture(ctx.agent)
    assert Runs.git_token(ctx.dctx, queued.id) == {:error, :not_found}
    assert Runs.git_token(ctx.dctx, -1) == {:error, :not_found}
  end

  test "an old authorization epoch is reauthorized", ctx do
    stale = %{ctx.dctx | auth_epoch: ctx.dctx.auth_epoch + 1}
    assert Runs.git_token(stale, ctx.run.id) == {:error, :reauthorized}
  end

  test "a repository no longer available, GitHub unavailable: unavailable with a reason",
       ctx do
    stub_push_tokens(fail: :all)

    assert Runs.git_token(ctx.dctx, ctx.run.id) ==
             {:error, {:unavailable, "GitHub is unavailable, retry later"}}

    Repo.update!(Ecto.Changeset.change(ctx.repository, archived: true))

    assert Runs.git_token(ctx.dctx, ctx.run.id) ==
             {:error, {:unavailable, "repository is not available"}}
  end
end
