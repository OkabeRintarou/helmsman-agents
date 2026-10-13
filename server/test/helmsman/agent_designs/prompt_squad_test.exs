defmodule Helmsman.AgentDesigns.PromptSquadTest do
  # add-squads 5.2: the prompt of a squad conversation's design run
  # (agent-design "小队对话的提示词", decision 12). The prompt of an agent
  # conversation is test/helmsman/agent_designs/prompt_test.exs, unchanged.
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns.{AgentDesign, AgentDesignMessage, Prompt}

  setup do
    ctx = design_fixture()
    {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {_carol, carol_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(carol_scope, %{name: "carol/qa", description: "Tests web apps"})
    view = start_squad_design!(ctx)
    Map.merge(ctx, %{id: view.id, bob: bob_scope.actor.name})
  end

  defp set_draft!(id, draft),
    do: Repo.update_all(from(d in AgentDesign, where: d.id == ^id), set: [draft: draft])

  defp prompt(id), do: Prompt.for_run(current_run!(id))

  test "the squad conversation's prompt", ctx do
    set_draft!(ctx.id, %{
      "agents" => [],
      "squad" => %{
        "name" => "web-team",
        "description" => "Builds the web app",
        "leader" => "web-lead",
        "instructions" => "Ship small pull requests.",
        "members" => [%{"name" => "carol/qa", "role_note" => "Tests"}]
      }
    })

    prompt = prompt(ctx.id)
    assert prompt =~ "design a squad"
    assert prompt =~ "propose_squad"
    assert prompt =~ "cannot create agents or change the squad"
    assert prompt =~ "- Squad leader:"
    assert prompt =~ "- #{ctx.bob} (person)"
    assert prompt =~ "- carol/qa (managed agent, claude): Tests web apps"
    assert prompt =~ "Squad (propose_squad): name web-team, leader web-lead"
    assert prompt =~ "  - carol/qa: \"Tests\""
    assert prompt =~ "members of the workspace can trigger the squad"
    refute prompt =~ "hmr_"
  end

  test "the bounds: 8 full agents, 16 members, 300 identities, a long history", ctx do
    long_grapheme = "e" <> String.duplicate("\u0301", 499)
    note = String.duplicate("😀", 250) <> long_grapheme
    instructions = String.duplicate("😀\"\\", 2730)
    assert byte_size(instructions) <= 16_384

    agent = fn i ->
      %{
        "name" => "agent-#{i}" <> String.duplicate("x", 50),
        "provider" => "claude",
        "runtime_id" => ctx.runtime.id,
        "provider_account_id" => nil,
        "model" => String.duplicate("m", 128),
        "effort" => String.duplicate("e", 128),
        "instructions" => String.duplicate("😀", 16_000),
        "description" => String.duplicate("😀", 1000),
        "capabilities" => ["create_tasks"],
        "access" => "workspace",
        "max_concurrency" => 16,
        "timeout_minutes" => 1200,
        "idle_timeout_minutes" => 240
      }
    end

    set_draft!(ctx.id, %{
      "agents" => Enum.map(1..8, agent),
      "squad" => %{
        "name" => String.duplicate("s", 64),
        "description" => String.duplicate("😀", 500),
        "leader" => String.duplicate("l", 64),
        "instructions" => instructions,
        "members" =>
          for(
            i <- 1..16,
            do: %{"name" => "m#{i}" <> String.duplicate("y", 60), "role_note" => note}
          )
      }
    })

    now = DateTime.utc_now()

    Repo.insert_all(
      Actor,
      for i <- 1..300 do
        %{
          workspace_id: ctx.workspace.id,
          kind: :agent,
          name: "ext-#{i}-" <> String.duplicate("z", 40),
          owner_id: ctx.alice.id,
          inserted_at: DateTime.truncate(now, :second),
          updated_at: DateTime.truncate(now, :second)
        }
      end
    )

    Repo.insert_all(
      AgentDesignMessage,
      for seq <- 2..40 do
        %{
          design_id: ctx.id,
          seq: seq,
          role: :assistant,
          content: String.duplicate("😀", 500),
          inserted_at: now
        }
      end
    )

    Repo.update_all(
      from(m in AgentDesignMessage, where: m.design_id == ^ctx.id and m.seq == 1),
      set: [content: String.duplicate("😀\n", 1638), seq: 41]
    )

    prompt = prompt(ctx.id)
    assert String.valid?(prompt)
    assert byte_size(prompt) <= 96 * 1024

    [_, options] = String.split(prompt, "Options for ", parts: 2)
    [options, _] = String.split(options, "Current draft", parts: 2)
    assert byte_size("Options for " <> options) <= 16 * 1024
    assert options =~ ~r/\(\d+ more people and agents omitted; call get_design for all of them\)/

    [_, squad] = String.split(prompt, "Squad (propose_squad):", parts: 2)
    [squad, _] = String.split(squad, "Conversation so far", parts: 2)
    assert byte_size(squad) <= 12 * 1024
    assert squad =~ "Call get_design for the full texts."
  end
end
