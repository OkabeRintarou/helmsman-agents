defmodule Helmsman.AgentDesigns.EditConfirmRaceTest do
  # add-edit-design-conversations 1.4: a confirm and a concurrent write, on
  # connections of their own (decision 9): no deadlock; the first to commit
  # wins, the other sees the baseline change or the running turn.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{AgentDesigns, Agents, CommittedData, LockHarness, Repo, Squads}

  @moduletag timeout: 60_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = edit_fixture()
        agent = settled(ctx, ctx.alice_scope, "fe-dev")
        put!(ctx, agent, %{"name" => "fe-dev", "model" => "opus"})
        squad = settled(ctx, ctx.carol_scope, "web-team")

        {:ok, _} =
          AgentDesigns.put_squad(ctx.carol_scope, squad, design!(squad).draft_version, %{
            "instructions" => "Ship it."
          })

        Map.merge(ctx, %{agent: agent, squad_design: squad})
      end)

    on_exit(fn ->
      CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, ctx.carol.id, ctx.dan.id])
    end)

    ctx
  end

  defp settled(ctx, scope, target) do
    %{id: id} = start_edit!(scope, target)
    end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "ok")
    id
  end

  defp put!(ctx, id, attrs),
    do: {:ok, _} = AgentDesigns.put_agent(ctx.alice_scope, id, design!(id).draft_version, attrs)

  defp confirm(ctx, id, scope \\ nil) do
    scope = scope || ctx.alice_scope
    fn -> AgentDesigns.confirm(scope, id, design!(id).draft_version) end
  end

  defp unboxed(fun), do: CommittedData.unboxed(fun)
  defp fe_dev(ctx), do: unboxed(fn -> profile(ctx.fe_dev) end)

  describe "with the page's edit of the agent" do
    defp page_edit(ctx), do: fn -> Agents.update(ctx.alice_scope, "fe-dev", %{model: "fable"}) end

    test "the confirm first: then the page's edit", ctx do
      assert {{:ok, _}, {:ok, _}} =
               LockHarness.interleave(confirm(ctx, ctx.agent), :commit, page_edit(ctx))

      assert fe_dev(ctx).model == "fable"
    end

    test "the page first: the confirm sees the baseline change", ctx do
      assert {{:ok, _}, {:error, {:baseline_changed, ["model"]}}} =
               LockHarness.interleave(page_edit(ctx), :commit, confirm(ctx, ctx.agent))

      assert fe_dev(ctx).model == "fable"
      d = unboxed(fn -> design!(ctx.agent) end)
      assert d.status == :open and hd(d.draft["agents"])["conflicts"] == ["model"]
    end
  end

  describe "with a message of the same conversation" do
    defp send_message(ctx), do: fn -> AgentDesigns.send(ctx.alice_scope, ctx.agent, "and?") end

    test "the confirm first: the message finds it closed", ctx do
      assert {{:ok, _}, {:error, :design_closed}} =
               LockHarness.interleave(confirm(ctx, ctx.agent), :commit, send_message(ctx))
    end

    test "the message first: the confirm finds the running turn", ctx do
      assert {{:ok, _}, {:error, :turn_running}} =
               LockHarness.interleave(send_message(ctx), :commit, confirm(ctx, ctx.agent))

      assert fe_dev(ctx).model == "sonnet"
    end
  end

  describe "a squad confirm with a member archived" do
    defp archive(ctx), do: fn -> Agents.archive(ctx.alice_scope, "fe-dev") end

    test "the confirm first: then the archive", ctx do
      assert {{:ok, _}, {:ok, _}} =
               LockHarness.interleave(
                 confirm(ctx, ctx.squad_design, ctx.carol_scope),
                 :commit,
                 archive(ctx)
               )

      {:ok, view} = unboxed(fn -> Squads.get(ctx.alice_scope, "web-team") end)
      assert view.instructions == "Ship it."
      refute "fe-dev" in Enum.map(view.members, & &1.name)
    end

    test "the archive first: the confirm sees the members change", ctx do
      assert {{:ok, _}, {:error, {:baseline_changed, ["members"]}}} =
               LockHarness.interleave(
                 archive(ctx),
                 :commit,
                 confirm(ctx, ctx.squad_design, ctx.carol_scope)
               )

      {:ok, view} = unboxed(fn -> Squads.get(ctx.alice_scope, "web-team") end)
      assert view.instructions == "Ship the web app."
    end
  end

  test "the user's draft edit and the confirm: one after the other", ctx do
    edit = fn ->
      AgentDesigns.put_agent(ctx.alice_scope, ctx.agent, 1, %{
        "name" => "fe-dev",
        "effort" => "low"
      })
    end

    assert {{:ok, _}, {:error, :stale}} =
             LockHarness.interleave(edit, :commit, fn ->
               AgentDesigns.confirm(ctx.alice_scope, ctx.agent, 1)
             end)

    assert unboxed(fn ->
             Repo.one(
               from(p in Helmsman.Agents.AgentProfile,
                 where: p.actor_id == ^ctx.fe_dev.id,
                 select: p.effort
               )
             )
           end) == "high"
  end
end
