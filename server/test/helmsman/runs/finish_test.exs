defmodule Helmsman.Runs.FinishTest do
  # add-daemon-git-workspace 1.6: `push_failed` ends write push_status
  # failed unless a push is recorded (decision 6).
  use Helmsman.DataCase, async: true

  import Helmsman.GitRunFixtures

  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.Report

  setup do
    git_run_fixture()
  end

  defp finish(ctx, reason) do
    {:ok, report} =
      Report.Finished.new(%{run_id: ctx.run.id, status: :failed, failure_reason: reason})

    Runs.finish(ctx.dctx, report)
  end

  defp reload(ctx), do: Repo.get!(Run, ctx.run.id)

  test "push_failed without a push: push_status failed", ctx do
    assert finish(ctx, :push_failed) == :ok
    assert %Run{status: :failed, failure_reason: :push_failed, push_status: :failed} = reload(ctx)
  end

  test "push_failed after a recorded push keeps pushed", ctx do
    set_run(ctx.run,
      push_status: :pushed,
      base_sha: sha("0"),
      head_sha: sha("a"),
      pushed_at: DateTime.utc_now()
    )

    assert finish(ctx, :push_failed) == :ok
    assert %Run{failure_reason: :push_failed, push_status: :pushed} = reload(ctx)
  end

  test "push_conflict does not change push_status", ctx do
    assert finish(ctx, :push_conflict) == :ok
    assert %Run{failure_reason: :push_conflict, push_status: :none} = reload(ctx)

    other = claimed_git_run(ctx)

    set_run(other,
      push_status: :conflict,
      base_sha: sha("0"),
      head_sha: sha("a"),
      rescue_branch: "#{ctx.branch}-run-#{other.id}",
      pushed_at: DateTime.utc_now()
    )

    assert finish(%{ctx | run: other}, :push_conflict) == :ok
    assert %Run{push_status: :conflict} = Repo.get!(Run, other.id)
  end

  test "other failures leave push_status alone", ctx do
    assert finish(ctx, :timeout) == :ok
    assert %Run{push_status: :none} = reload(ctx)
  end
end
