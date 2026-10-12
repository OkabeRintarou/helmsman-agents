defmodule Helmsman.Runs.PushedTest do
  # add-daemon-git-workspace 1.5: recording a push (decision 5).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.GitRunFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Runs}
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.Report

  setup do
    ctx = git_run_fixture()
    test = self()
    handler = "after-push-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:helmsman, :runs, :after_push],
      &__MODULE__.forward_after_push/4,
      test
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    ctx
  end

  @doc false
  def forward_after_push(_event, _measurements, %{run_id: id}, test),
    do: send(test, {:after_push, id})

  defp pushed(ctx, attrs \\ %{}) do
    {:ok, report} =
      Report.Pushed.new(
        Map.merge(
          %{
            run_id: ctx.run.id,
            branch: ctx.branch,
            base_sha: sha("0"),
            head_sha: sha("a"),
            commits: [%{sha: sha("a"), subject: "BOS-1: add login"}],
            rescue_branch: nil
          },
          attrs
        )
      )

    report
  end

  defp reload(run), do: Repo.get!(Run, run.id)

  test "a late push (scenario): recorded on a run failed runtime_offline", ctx do
    set_run(ctx.run,
      status: :failed,
      failure_reason: :runtime_offline,
      finished_at: DateTime.utc_now()
    )

    assert Runs.pushed(ctx.dctx, pushed(ctx)) == :ok

    head = sha("a")

    assert %Run{
             status: :failed,
             failure_reason: :runtime_offline,
             push_status: :pushed,
             head_sha: ^head,
             rescue_branch: nil,
             pushed_at: %DateTime{}
           } = run = reload(ctx.run)

    assert run.base_sha == sha("0")
    assert run.push_commits == [%{"sha" => head, "subject" => "BOS-1: add login"}]
  end

  test "a push after a push_failed end (scenario); resend; another head", ctx do
    {:ok, finished} =
      Report.Finished.new(%{
        run_id: ctx.run.id,
        status: :failed,
        failure_reason: :push_failed,
        error: "push failed: network"
      })

    assert Runs.finish(ctx.dctx, finished) == :ok

    assert %Run{status: :failed, failure_reason: :push_failed, push_status: :failed} =
             reload(ctx.run)

    assert Runs.pushed(ctx.dctx, pushed(ctx)) == :ok

    assert %Run{status: :failed, failure_reason: :push_failed, push_status: :pushed} =
             recorded = reload(ctx.run)

    assert Runs.pushed(ctx.dctx, pushed(ctx)) == :ok
    assert reload(ctx.run) == recorded

    assert Runs.pushed(ctx.dctx, pushed(ctx, %{head_sha: sha("b")})) == {:error, :wrong_state}

    assert %Run{status: :failed, failure_reason: :push_failed, push_status: :pushed} =
             reload(ctx.run)

    assert reload(ctx.run).head_sha == sha("a")
  end

  test "pushed to a rescue branch (scenario): conflict", ctx do
    rescue_branch = "#{ctx.branch}-run-#{ctx.run.id}"
    assert Runs.pushed(ctx.dctx, pushed(ctx, %{rescue_branch: rescue_branch})) == :ok

    assert %Run{push_status: :conflict, rescue_branch: ^rescue_branch} = reload(ctx.run)

    # The same push again is fine; without the rescue branch it is another push.
    assert Runs.pushed(ctx.dctx, pushed(ctx, %{rescue_branch: rescue_branch})) == :ok
    assert Runs.pushed(ctx.dctx, pushed(ctx)) == {:error, :wrong_state}
  end

  test "another branch (scenario): invalid_payload, nothing written", ctx do
    assert {:error, {:invalid_payload, :branch}} =
             Runs.pushed(ctx.dctx, pushed(ctx, %{branch: "hm/#{ctx.workspace.id}/bos-99"}))

    assert %Run{push_status: :none, pushed_at: nil, head_sha: nil} = reload(ctx.run)
  end

  test "resend and conflict (scenario)", ctx do
    assert Runs.pushed(ctx.dctx, pushed(ctx)) == :ok
    recorded = reload(ctx.run)
    Events.subscribe(Events.topic(:run, ctx.run.id))

    assert Runs.pushed(ctx.dctx, pushed(ctx)) == :ok
    assert reload(ctx.run) == recorded
    refute_receive {:run_updated, _}

    assert Runs.pushed(ctx.dctx, pushed(ctx, %{head_sha: sha("c")})) == {:error, :wrong_state}
    assert reload(ctx.run) == recorded
  end

  test "reporting for an earlier run: rescue branch of a run of the same task and daemon",
       ctx do
    later = claimed_git_run(ctx, %{status: :running})

    set_run(ctx.run,
      status: :failed,
      failure_reason: :push_failed,
      finished_at: DateTime.utc_now()
    )

    for_earlier = pushed(ctx, %{rescue_branch: "#{ctx.branch}-run-#{later.id}"})
    assert Runs.pushed(ctx.dctx, for_earlier) == :ok
    assert reload(ctx.run).push_status == :conflict

    # Runs of another daemon or another task do not make a valid rescue branch.
    {other, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
    theirs = claimed_git_run(ctx, %{status: :failed, daemon_id: other.id})
    other_task = task_fixture(ctx.alice_scope, ctx.project.key)
    elsewhere = claimed_git_run(ctx, %{status: :failed, task_id: other_task.id})

    for id <- [theirs.id, elsewhere.id] do
      report = pushed(ctx, %{run_id: later.id, rescue_branch: "#{ctx.branch}-run-#{id}"})
      assert Runs.pushed(ctx.dctx, report) == {:error, {:invalid_payload, :rescue_branch}}
    end

    for bad <- ["#{ctx.branch}-run-0#{later.id}", "#{ctx.branch}-run-x", "other-run-#{later.id}"] do
      report = pushed(ctx, %{run_id: later.id, rescue_branch: bad})
      assert Runs.pushed(ctx.dctx, report) == {:error, {:invalid_payload, :rescue_branch}}
    end

    assert reload(later).pushed_at == nil
  end

  test "SHAs, the number of commits and subjects are checked", ctx do
    commit = %{sha: sha("a"), subject: "x"}

    invalid = [
      %{head_sha: String.upcase(sha("a"))},
      %{base_sha: String.duplicate("a", 39)},
      %{head_sha: "not-a-sha"},
      %{commits: List.duplicate(commit, 251)},
      %{commits: [%{commit | sha: String.duplicate("A", 40)}]},
      %{commits: [%{commit | subject: String.duplicate("é", 513)}]}
    ]

    for attrs <- invalid do
      assert {:error, {:invalid_payload, _why}} = Runs.pushed(ctx.dctx, pushed(ctx, attrs))
    end

    assert reload(ctx.run).pushed_at == nil

    assert Runs.pushed(
             ctx.dctx,
             pushed(ctx, %{
               commits: List.duplicate(%{commit | subject: String.duplicate("a", 1024)}, 250)
             })
           ) == :ok
  end

  test "who may report: own runs with a repository, current epoch", ctx do
    {other, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
    assert Runs.pushed(daemon_ctx(other), pushed(ctx)) == {:error, :not_found}

    queued = run_fixture(ctx.agent, %{task_id: ctx.task.id})
    assert queued.daemon_id == nil
    assert Runs.pushed(ctx.dctx, pushed(ctx, %{run_id: queued.id})) == {:error, :not_found}

    plain = claimed_git_run(ctx, %{task_id: nil, repository_id: nil, branch: nil})
    assert Runs.pushed(ctx.dctx, pushed(ctx, %{run_id: plain.id})) == {:error, :wrong_state}

    stale = %{ctx.dctx | auth_epoch: ctx.dctx.auth_epoch + 1}
    assert Runs.pushed(stale, pushed(ctx)) == {:error, :reauthorized}
    assert reload(ctx.run).pushed_at == nil
  end

  test "after the commit: three topics and after_push once", ctx do
    id = ctx.run.id
    task_id = ctx.task.id
    Events.subscribe(Events.topic(:run, id))
    Events.subscribe(Events.topic(:workspace_runs, ctx.workspace.id))
    Events.subscribe(Events.topic(:task, task_id))

    assert Runs.pushed(ctx.dctx, pushed(ctx)) == :ok
    assert_receive {:run_updated, %{id: ^id}}
    assert_receive {:run_updated, %{id: ^id}}
    assert_receive {:runs_changed, _ident}
    assert_receive {:after_push, ^id}

    assert Runs.pushed(ctx.dctx, pushed(ctx)) == :ok
    refute_receive {:after_push, ^id}
  end

  test "nothing happens before the commit", ctx do
    Events.subscribe(Events.topic(:run, ctx.run.id))

    Helmsman.Tx.run(fn ->
      assert Runs.pushed(ctx.dctx, pushed(ctx)) == :ok
      refute_received {:run_updated, _}
      refute_received {:after_push, _}
      {:error, :rollback}
    end)

    assert reload(ctx.run).pushed_at == nil
  end
end
