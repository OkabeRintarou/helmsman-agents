defmodule HelmsmanMCP.Tools.CancelRunTest do
  # add-run-lifecycle 6.3: the `cancel_run` tool (decision 21).
  use Helmsman.DataCase, async: true

  import Helmsman.RunsFixtures
  import HelmsmanMCP.ToolHelpers

  alias Helmsman.Runs.Run
  alias HelmsmanMCP.Pipeline
  alias HelmsmanMCP.Tools.CancelRun

  setup do
    ctx = dispatch_fixture()
    {_bob, bob_scope} = member_scope_fixture(ctx.workspace)

    Map.merge(ctx, %{
      alice: mcp_session(ctx.alice, ctx.workspace),
      bob: mcp_session(bob_scope.user, ctx.workspace),
      daemon: daemon_of(ctx.agent)
    })
  end

  test "stops a running run and returns its summary", ctx do
    run = run_fixture(ctx.agent, %{status: :running, daemon_id: ctx.daemon.id})

    assert {:ok, %{"run" => %{"id" => id, "status" => "CANCELLING"}}} =
             call(ctx.alice, "cancel_run", %{"run_id" => run.id})

    assert id == run.id
    assert Repo.get!(Run, run.id).status == :cancelling
  end

  test "an ended run: already finished", ctx do
    run = run_fixture(ctx.agent, %{status: :succeeded})
    assert {:error, text} = call(ctx.alice, "cancel_run", %{"run_id" => run.id})
    assert text =~ "Run #{run.id} has already ended"
  end

  test "a member with nothing to do with the run may not; an unknown run is not found", ctx do
    run = run_fixture(ctx.agent)
    assert {:error, text} = call(ctx.bob, "cancel_run", %{"run_id" => run.id})
    assert text =~ "cannot do this"
    assert Repo.get!(Run, run.id).status == :queued

    assert {:error, text} = call(ctx.alice, "cancel_run", %{"run_id" => 999_999_999})
    assert text =~ "Run 999999999 not found"
  end

  test "a run token is forbidden", ctx do
    run = run_fixture(ctx.agent, %{status: :running, daemon_id: ctx.daemon.id})
    {scope, _token} = run_scope_fixture(run)

    assert {:error, text} = Pipeline.call_module(CancelRun, %{"run_id" => run.id}, scope, nil)
    assert text =~ "This run can only read the workspace"
    assert Repo.get!(Run, run.id).status == :running
  end
end
