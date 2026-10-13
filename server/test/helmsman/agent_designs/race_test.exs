defmodule Helmsman.AgentDesigns.RaceTest do
  # add-agent-conversation 3.1, 3.5, 4.1: races between connections of
  # their own, outside the sandbox (decisions 7, 11, 12).
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AgentDesignsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{AgentDesigns, CommittedData, Repo}
  alias Helmsman.AgentDesigns.{AgentDesign, Draft}
  alias HelmsmanMCP.Pipeline
  alias HelmsmanMCP.Tools.ProposeAgent

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = design_fixture()
        {bob, bob_scope} = member_scope_fixture(ctx.workspace)
        Map.merge(ctx, %{bob: bob, bob_scope: bob_scope})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id]) end)
    Map.put(ctx, :parent, self())
  end

  defp start(fun) do
    Task.async(fn -> CommittedData.unboxed(fun) end)
  end

  defp unboxed(fun), do: CommittedData.unboxed(fun)

  defp pause_at(point, parent) do
    Process.put(:helmsman_test_hook, fn
      ^point ->
        send(parent, {:paused, self()})

        receive do
          :go -> :ok
        end

      _other ->
        :ok
    end)
  end

  defp settled_design(ctx) do
    unboxed(fn ->
      %{id: id} = start_design!(ctx.alice_scope)
      end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "ok")
      id
    end)
  end

  defp put!(ctx, id, name) do
    unboxed(fn ->
      {:ok, _} =
        AgentDesigns.put_agent(ctx.alice_scope, id, design!(id).draft_version, %{
          name: name,
          provider: "claude",
          runtime_id: ctx.runtime.id,
          instructions: "You are #{name}."
        })
    end)
  end

  test "two starts at once: one conversation, the other gets design_open with its ID", ctx do
    # Both pass the check for an open conversation before either inserts.
    tasks =
      for _ <- 1..2 do
        start(fn ->
          pause_at(:design_start_checked, ctx.parent)
          AgentDesigns.start(ctx.alice_scope, %{helper: "helper", message: "hi"})
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:paused, pid}, 5_000
        pid
      end

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert [{:ok, %{id: id}}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:error, {:design_open, id}} in results

    assert unboxed(fn ->
             Repo.aggregate(from(d in AgentDesign, where: d.user_id == ^ctx.alice.id), :count)
           end) == 1
  end

  test "a name taken between the check and the insert: everything rolls back", ctx do
    id = settled_design(ctx)
    put!(ctx, id, "fe-dev")
    put!(ctx, id, "pr-reviewer")
    version = unboxed(fn -> design!(id).draft_version end)

    alice =
      start(fn ->
        pause_at(:confirm_validated, ctx.parent)
        AgentDesigns.confirm(ctx.alice_scope, id, version)
      end)

    assert_receive {:paused, pid}, 5_000
    unboxed(fn -> managed_agent_fixture(ctx.bob_scope, %{name: "pr-reviewer"}) end)
    send(pid, :go)

    assert {:error, {:invalid, %{"pr-reviewer" => cs}}} = Task.await(alice, 5_000)
    assert {"has already been taken", _} = cs.errors[:name]

    unboxed(fn ->
      refute Repo.get_by(Actor, workspace_id: ctx.workspace.id, name: "fe-dev")
      assert design!(id).status == :open
    end)
  end

  test "an in-flight propose_agent after the turn was stopped and the draft edited is " <>
         "refused; the draft has only the user's edit (scenario)",
       ctx do
    {id, scope} =
      unboxed(fn ->
        %{id: id} = start_design!(ctx.alice_scope)
        {scope, _token} = design_run_scope!(ctx, id)
        {id, scope}
      end)

    helper =
      start(fn ->
        pause_at(:design_entry_checked, ctx.parent)

        Pipeline.call_module(
          ProposeAgent,
          %{"name" => "ai-agent", "provider" => "claude", "instructions" => "x"},
          scope,
          nil
        )
      end)

    assert_receive {:paused, pid}, 5_000
    unboxed(fn -> {:ok, _} = AgentDesigns.stop_turn(ctx.alice_scope, id) end)
    put!(ctx, id, "user-agent")
    send(pid, :go)

    assert {:error, text} = Task.await(helper, 5_000)
    assert text =~ "This design turn has ended"

    assert unboxed(fn -> Enum.map(Draft.agents(design!(id).draft), & &1["name"]) end) ==
             ["user-agent"]
  end
end
