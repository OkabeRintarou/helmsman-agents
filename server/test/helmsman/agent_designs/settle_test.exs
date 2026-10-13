defmodule Helmsman.AgentDesigns.SettleTest do
  # add-agent-conversation 3.3: settling a turn (decision 9).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentDesignsFixtures

  alias Helmsman.{AgentDesigns, Events, Runs, Tx}
  alias Helmsman.AgentDesigns.SettleTurn
  alias Helmsman.Runs.Run

  setup do
    ctx = design_fixture()
    %{id: id} = start_design!(ctx.alice_scope)
    Events.subscribe(AgentDesigns.topic(id))
    Map.put(ctx, :id, id)
  end

  test "a successful turn: the reply, no current turn, the next message works (scenario)",
       ctx do
    run = run_turn!(ctx, ctx.id)
    reply = "我建议用 sonnet…你希望它负责 Storybook 吗？"
    assert {:ok, :settled} = end_and_settle!(run, :succeeded, summary: reply)

    assert %{role: :assistant, content: ^reply} = List.last(messages!(ctx.id))
    assert design!(ctx.id).current_run_id == nil
    assert_receive {:agent_design, id} when id == ctx.id
    assert {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "yes")
  end

  test "a failed turn: a system message with the reason (scenario)", ctx do
    end_and_settle!(run_turn!(ctx, ctx.id), :failed, failure_reason: :provider_auth)

    assert %{role: :system, code: "failed", detail: "provider_auth"} =
             List.last(messages!(ctx.id))

    assert design!(ctx.id).current_run_id == nil
  end

  test "an empty output: no_reply; a cancelled run: cancelled", ctx do
    end_and_settle!(run_turn!(ctx, ctx.id), :succeeded, summary: "  ")
    assert %{role: :system, code: "no_reply"} = List.last(messages!(ctx.id))

    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "again")
    run = current_run!(ctx.id)

    {:ok, 1} =
      Tx.run(fn ->
        {:ok, Runs.cancel_pending(from(r in Run, where: r.id == ^run.id), :obsolete)}
      end)

    assert_enqueued(worker: SettleTurn, args: %{run_id: run.id})
    perform_job(SettleTurn, %{run_id: run.id})
    assert %{role: :system, code: "cancelled", detail: "obsolete"} = List.last(messages!(ctx.id))
  end

  test "settling twice: one message (scenario)", ctx do
    run = run_turn!(ctx, ctx.id)
    end_and_settle!(run, :succeeded, summary: "hi")
    assert AgentDesigns.settle(run.id) == {:ok, :skipped}
    perform_job(SettleTurn, %{run_id: run.id})

    assert length(messages!(ctx.id)) == 2
  end

  test "a run that is no longer the turn writes nothing", ctx do
    run = run_turn!(ctx, ctx.id)
    {:ok, _} = AgentDesigns.stop_turn(ctx.alice_scope, ctx.id)
    count = length(messages!(ctx.id))

    assert end_and_settle!(Repo.get!(Run, run.id), :cancelled) == {:ok, :skipped}
    assert length(messages!(ctx.id)) == count
  end
end
