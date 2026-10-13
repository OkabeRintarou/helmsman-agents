defmodule Helmsman.AgentDesigns.PromptTest do
  # add-agent-conversation 2.5: the prompt of a design run (decisions 8, 16).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.AgentDesigns
  alias Helmsman.AgentDesigns.{AgentDesign, AgentDesignMessage, Prompt}
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Repo

  @snapshot Path.expand("../../fixtures/agent_design_prompt.txt", __DIR__)

  setup do
    ctx = design_fixture(%{instructions: "You are a backend dev."})
    Map.put(ctx, :id, start_design!(ctx.alice_scope, "Build a frontend developer").id)
  end

  defp prompt(id), do: Prompt.for_run(current_run!(id))

  defp settle_turn(ctx, reply) do
    end_and_settle!(run_turn!(ctx, ctx.id), :succeeded, summary: reply)
  end

  defp version(id), do: design!(id).draft_version

  defp fe_dev(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        name: "fe-dev",
        provider: "claude",
        runtime_id: ctx.runtime.id,
        model: "sonnet",
        effort: "high",
        instructions: "You build the web UI with Tailwind."
      },
      attrs
    )
  end

  defp put!(ctx, attrs) do
    {:ok, _} = AgentDesigns.put_agent(ctx.alice_scope, ctx.id, version(ctx.id), attrs)
  end

  test "the whole prompt (scenario)", ctx do
    settle_turn(ctx, "I suggest sonnet. Should it own Storybook?")
    put!(ctx, fe_dev(ctx))
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "指令里加上 Storybook")
    text = prompt(ctx.id)

    refute text =~ "You are a backend dev."
    assert text =~ "propose_agent"
    assert text =~ "Role examples (examples only"
    assert text =~ "- #{ctx.runtime.id}: claude on alice-mbp, online; models fable, opus, sonnet"
    assert text =~ "- fe-dev: claude, runtime #{ctx.runtime.id}"
    assert text =~ "model sonnet, effort high"
    assert text =~ "[user] Build a frontend developer"
    assert text =~ "[you] I suggest sonnet. Should it own Storybook?"
    assert text =~ "The user's new message:\n> 指令里加上 Storybook\n"
    refute text =~ "hmr_"
  end

  test "system messages are English sentences; every line of the new message is quoted", ctx do
    end_and_settle!(run_turn!(ctx, ctx.id), :failed, failure_reason: :provider_auth)
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "line one\nline two\n\nline four")
    {:ok, _} = AgentDesigns.stop_turn(ctx.alice_scope, ctx.id)
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "again")
    text = prompt(ctx.id)

    assert text =~ "[system] The turn failed (provider_auth)."
    assert text =~ "[system] The turn was stopped by the user."
    assert text =~ "[user] line one\nline two\n\nline four\n"

    {:ok, _} = AgentDesigns.stop_turn(ctx.alice_scope, ctx.id)
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "a\nb\n\nc")
    assert prompt(ctx.id) =~ "The user's new message:\n> a\n> b\n> \n> c\n"
  end

  test "without any runtime or provider account: the options say so", ctx do
    Repo.update_all(from(p in AgentProfile, where: p.actor_id == ^ctx.helper.id),
      set: [access: "workspace"]
    )

    {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
    %{id: id} = start_design!(bob_scope)
    text = prompt(id)

    assert text =~ "There is no runtime or provider account"
    refute text =~ "alice-mbp"
  end

  test "edits are replayed when the turn is claimed later (scenario)", ctx do
    settle_turn(ctx, "ok")
    put!(ctx, fe_dev(ctx))
    put!(ctx, %{name: "qa", provider: "claude", instructions: "You test."})
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "看看")
    settle_turn(ctx, "done")

    put!(ctx, %{name: "fe-dev", model: "opus"})
    {:ok, _} = AgentDesigns.remove_agent(ctx.alice_scope, ctx.id, version(ctx.id), "qa")
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "再看看")
    assert design!(ctx.id).pending_edits == []

    # Claimed in another transaction, after the send committed.
    text = prompt(ctx.id)
    assert text =~ "The user changed the draft before this message: fe-dev (model); removed qa."

    # The next turn: no new edits; the earlier message keeps them (scenario).
    settle_turn(ctx, "ok")
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "next")
    text = prompt(ctx.id)
    refute text =~ "The user changed the draft before this message"
    assert text =~ "[user edited the draft: fe-dev (model); removed qa]\n[user] 再看看"
  end

  test "a turn stopped before it was claimed keeps its edits in the history", ctx do
    settle_turn(ctx, "ok")
    put!(ctx, fe_dev(ctx))
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "first")
    {:ok, _} = AgentDesigns.stop_turn(ctx.alice_scope, ctx.id)
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "second")
    text = prompt(ctx.id)

    refute text =~ "The user changed the draft before this message"
    assert text =~ "[user edited the draft: added fe-dev]\n[user] first"
  end

  test "a long history keeps the latest messages within 48 KB (scenario)", ctx do
    settle_turn(ctx, "ok")
    # 60 KB of earlier messages.
    insert_messages(ctx.id, for(i <- 1..30, do: {"m#{i} " <> String.duplicate("x", 2040)}))
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "now")
    text = prompt(ctx.id)
    history = section(text, "Conversation so far", "The user's new message:")

    assert byte_size(history) <= 48 * 1024
    assert history =~ ~r/^Conversation so far \(\d+ earlier messages omitted\):/
    assert history =~ "m30 "
    refute history =~ "m1 "
  end

  test "the largest input stays within the bounds", ctx do
    settle_turn(ctx, "ok")

    for i <- 1..40 do
      {daemon, _} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})

      runtime_fixture(ctx.workspace, daemon, %{
        provider: "claude",
        models: for(m <- 1..20, do: "model-#{i}-#{m}-xxxxxxxx"),
        efforts: ["low", "medium", "high"]
      })
    end

    agent = fn n ->
      Map.merge(AgentDesigns.Draft.defaults(), %{
        "name" => "agent-#{n}-" <> String.duplicate("n", 50),
        "provider" => "claude",
        "model" => String.duplicate("m", 128),
        "effort" => String.duplicate("e", 128),
        "description" => String.duplicate("描", 1000),
        "instructions" => String.duplicate("指", 21_000),
        "updated_by" => "ai"
      })
    end

    Repo.update_all(from(d in AgentDesign, where: d.id == ^ctx.id),
      set: [draft: %{"agents" => Enum.map(1..8, agent)}]
    )

    insert_messages(ctx.id, for(i <- 1..39, do: {"#{i} " <> String.duplicate("ü", 4090)}))
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, String.duplicate("x\n", 4096))
    text = prompt(ctx.id)

    assert byte_size(section(text, "Options for", "Current draft")) <= 16 * 1024
    assert text =~ ~r/\(\d+ more runtimes omitted; call get_design for all of them\)/
    assert byte_size(section(text, "Conversation so far", "The user's new message:")) <= 48 * 1024
    assert byte_size(text) <= 96 * 1024
  end

  test "single graphemes of combining marks stay within the bounds (code review 1)", ctx do
    settle_turn(ctx, "ok")
    # One grapheme each: 63 001 and 2 001 bytes, valid drafts.
    long = "a" <> String.duplicate("\u20d0", 21_000)
    description = "d" <> String.duplicate("\u20d0", 666)
    assert String.length(long) == 1 and byte_size(long) <= 65_536

    for i <- 1..8 do
      put!(ctx, %{
        name: "agent-#{i}",
        provider: "claude",
        instructions: long,
        description: description
      })
    end

    for i <- 1..32 do
      Helmsman.ProviderAccountsFixtures.provider_account_fixture(ctx.alice, %{
        name: "acct-#{i}-" <> String.duplicate("名", 50)
      })
    end

    # The most lines an 8 KB message can have.
    {:ok, _} =
      AgentDesigns.send(ctx.alice_scope, ctx.id, "a" <> String.duplicate("\n", 8191))

    text = prompt(ctx.id)
    draft = section(text, "Current draft", "Conversation so far")

    assert byte_size(text) <= 96 * 1024
    assert byte_size(section(text, "Options for", "Current draft")) <= 16 * 1024
    assert byte_size(draft) <= 8 * 2048 + 1024
    assert draft =~ "instructions 63001 bytes: \"a"
    assert draft =~ "(call get_design for the full text)"
    assert String.valid?(text)
  end

  test "quoting escapes quotes, backslashes and control characters", ctx do
    settle_turn(ctx, "ok")
    put!(ctx, %{name: "q", provider: "claude", instructions: "say \"hi\"\\n\tnow\nnext"})
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "go")

    assert prompt(ctx.id) =~ ~S(instructions 19 bytes: "say \"hi\"\\n now next")
  end

  test "the whole prompt, as a snapshot", ctx do
    settle_turn(ctx, "I suggest sonnet with effort high. Should it own Storybook?")
    put!(ctx, fe_dev(ctx, %{description: "Builds the web UI"}))
    put!(ctx, %{name: "fe-dev", model: "opus"})
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "Yes, and add Storybook.")

    text =
      ctx.id
      |> prompt()
      |> String.replace(ctx.workspace.slug, "<slug>")
      |> String.replace(ctx.alice.display_name, "<user>")
      |> String.replace(ctx.alice_scope.actor.name, "<human>")
      |> String.replace("#{ctx.runtime.id}", "<runtime>")

    if System.get_env("UPDATE_SNAPSHOTS") == "1", do: File.write!(@snapshot, text)
    assert text == File.read!(@snapshot)
  end

  defp insert_messages(id, contents) do
    start = Repo.one(from(m in AgentDesignMessage, where: m.design_id == ^id, select: max(m.seq)))

    contents
    |> Enum.with_index(start + 1)
    |> Enum.each(fn {{content}, seq} ->
      Repo.insert!(%AgentDesignMessage{
        design_id: id,
        seq: seq,
        role: if(rem(seq, 2) == 0, do: :user, else: :assistant),
        content: content,
        edits: [],
        inserted_at: DateTime.utc_now()
      })
    end)
  end

  defp section(text, from, to) do
    [_, rest] = String.split(text, from, parts: 2)
    [body, _] = String.split(rest, to, parts: 2)
    from <> body
  end
end
