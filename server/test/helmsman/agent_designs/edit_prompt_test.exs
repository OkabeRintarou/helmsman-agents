defmodule Helmsman.AgentDesigns.EditPromptTest do
  # add-edit-design-conversations 1.5: agent-design 「修改对话的提示词」
  # (decision 11).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{AgentDesigns, Agents}
  alias Helmsman.AgentDesigns.{AgentDesign, AgentDesignMessage, Prompt}

  setup do
    ctx = edit_fixture()

    {:ok, _} =
      Agents.update(ctx.alice_scope, "fe-dev", %{env: %{"API_TOKEN" => "s3cret-value"}})

    ctx
  end

  defp prompt(id), do: Prompt.for_run(current_run!(id))
  defp version(id), do: design!(id).draft_version

  defp settled(ctx, scope, target) do
    %{id: id} = start_edit!(scope, target)
    end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "ok")
    id
  end

  defp put!(scope, id, attrs),
    do:
      {:ok, _} = AgentDesigns.put_agent(scope, id, version(id), Map.put(attrs, "name", "fe-dev"))

  test "the owner's agent_edit prompt", ctx do
    id = settled(ctx, ctx.alice_scope, "fe-dev")
    put!(ctx.alice_scope, id, %{"model" => "opus"})
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, id, "Also Storybook?")
    text = prompt(id)

    assert text =~ ~s{edit the existing managed agent "fe-dev" (owner: #{ctx.alice.display_name})}
    assert text =~ "You cannot rename, disable, archive or delete the agent"
    assert text =~ ~s{propose_agent(name: "fe-dev", ...)}
    assert text =~ "model: sonnet → opus"
    assert text =~ "- #{ctx.runtime.id}: claude on alice-mbp"
    assert text =~ "Baseline (version"
    assert text =~ "The user changed the draft before this message: fe-dev (model)."
    refute text =~ "Role examples"
    refute text =~ "s3cret-value"
    refute text =~ "hmr_"
    assert byte_size(text) <= 96 * 1024
  end

  test "an admin's prompt: the read-only fields, no runtimes or accounts", ctx do
    id = settled(ctx, ctx.carol_scope, "fe-dev")
    {:ok, _} = AgentDesigns.send(ctx.carol_scope, id, "Lower the concurrency")
    text = prompt(id)

    assert text =~ "is not the owner: these fields are read-only and must not be proposed:"
    assert text =~ "instructions"
    assert text =~ "are read-only here (only its owner #{ctx.alice.display_name} can change them)"
    refute text =~ "Runtimes (runtime_id)"
    refute text =~ "Provider accounts (provider_account_id"
  end

  test "after a rebaseline the next turn tells the helper", ctx do
    id = settled(ctx, ctx.alice_scope, "fe-dev")
    put!(ctx.alice_scope, id, %{"effort" => "medium"})
    {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{effort: "low"})

    assert {:error, {:baseline_changed, ["effort"]}} =
             AgentDesigns.confirm(ctx.alice_scope, id, version(id))

    {:ok, _} = AgentDesigns.send(ctx.alice_scope, id, "What now?")
    text = prompt(id)

    assert text =~ "someone else changed effort on the target"
    assert text =~ "Conflicts (someone changed these on the target meanwhile"
    assert text =~ "effort: low → medium"
  end

  test "a long diff is cut at 8 KB and points to get_design", ctx do
    id = settled(ctx, ctx.alice_scope, "fe-dev")
    long = Enum.map_join(1..900, "\n", &"line #{&1} of the new instructions")
    put!(ctx.alice_scope, id, %{"instructions" => long})
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, id, "ok")
    text = prompt(id)

    assert text =~ "instructions: changed (diff too long here; read it with get_design)"
    assert byte_size(text) <= 96 * 1024
  end

  test "the squad_edit prompt: the squad, new agents, no renaming", ctx do
    id = settled(ctx, ctx.alice_scope, "web-team")

    {:ok, _} =
      AgentDesigns.put_agent(ctx.alice_scope, id, version(id), %{
        "name" => "qa",
        "provider" => "claude",
        "runtime_id" => ctx.runtime.id,
        "instructions" => "You test."
      })

    {:ok, _} = AgentDesigns.send(ctx.alice_scope, id, "Add qa as a member")
    text = prompt(id)

    assert text =~ ~s{edit the existing squad "web-team"}
    assert text =~ "suggest an edit conversation for that agent"
    assert text =~ "New agents:\n- qa: claude"
    assert text =~ "Squad (propose_squad): name web-team, leader web-lead"
    assert text =~ "  - fe-dev: \"前端\""
    assert byte_size(text) <= 96 * 1024
  end

  test "the largest edit conversation stays within the bounds", ctx do
    id = settled(ctx, ctx.alice_scope, "fe-dev")
    big = String.duplicate("指", 21_000)

    put!(ctx.alice_scope, id, %{
      "instructions" => big,
      "description" => String.duplicate("描", 333)
    })

    start = Repo.one(from(m in AgentDesignMessage, where: m.design_id == ^id, select: max(m.seq)))

    for i <- 1..40 do
      Repo.insert!(%AgentDesignMessage{
        design_id: id,
        seq: start + i,
        role: if(rem(i, 2) == 0, do: :user, else: :assistant),
        content: "#{i} " <> String.duplicate("ü", 2000),
        edits: [],
        inserted_at: DateTime.utc_now()
      })
    end

    Repo.update_all(from(d in AgentDesign, where: d.id == ^id), set: [user_messages: 1])
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, id, String.duplicate("x\n", 4096))
    text = prompt(id)

    assert byte_size(text) <= 96 * 1024
    assert String.valid?(text)
    assert text =~ ~r/Conversation so far \(\d+ earlier messages omitted\)/
  end

  test "sixteen members and long squad texts stay within the bounds", ctx do
    for i <- 1..14 do
      Helmsman.AgentsFixtures.managed_agent_fixture(ctx.alice_scope, %{
        name: "member-#{i}",
        runtime_id: ctx.runtime.id
      })
    end

    members =
      [%{name: "fe-dev", role_note: String.duplicate("注", 166)}, %{name: ctx.bob_name}] ++
        for(i <- 1..14, do: %{name: "member-#{i}", role_note: String.duplicate("注", 166)})

    {:ok, _} =
      Helmsman.Squads.update(ctx.alice_scope, "web-team", %{
        members: members,
        instructions: String.duplicate("说", 3000)
      })

    id = settled(ctx, ctx.alice_scope, "web-team")
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, id, "go")
    text = prompt(id)

    assert byte_size(text) <= 96 * 1024
    assert String.valid?(text)
  end
end
