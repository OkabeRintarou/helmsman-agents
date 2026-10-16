defmodule Helmsman.AgentDesigns.Prompt do
  @moduledoc """
  The prompt of a design run (`add-agent-conversation` decision 8),
  generated when the run is claimed, in English, without the helper's own
  instructions, in six parts: how the conversation works, role examples,
  the options of the conversation's user (at most #{16} KB, online
  runtimes first), the draft with the edits the user made before this
  turn's message (decision 16), the conversation so far (at most #{48} KB,
  the latest messages kept) and this turn's message quoted with `> `.

  Bounded by construction to #{96} KB of UTF-8, every part measured in
  bytes: the intro and examples are constants (the names in them are at
  most 64 characters); the options at most 16 KB; the draft summary at
  most 8 agents of bounded fields, with at most 200 bytes of description
  and 400 of instructions, cut between code points and quoted (at most
  twice as long), about 2 KB each, and the user's edits; this turn's
  message at most 8 KB, three times that once every line is quoted. That
  is under 64 KB; the history gets what is left of 96 KB, at most 48 KB.
  Holds no token, key or environment value: options list IDs, names and
  CLIs only.
  """

  import Ecto.Query

  alias Helmsman.Accounts.User
  alias Helmsman.Actors.Actor

  alias Helmsman.AgentDesigns.{
    AgentDesign,
    AgentDesignMessage,
    Changes,
    Draft,
    Edit,
    Options,
    SquadDraft
  }

  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias Helmsman.Workspaces.Workspace

  @options_bytes 16 * 1024
  @history_bytes 48 * 1024
  @prompt_bytes 96 * 1024
  # Room for the history's heading within its bound.
  @heading_bytes 64
  # Draft summary excerpts, in bytes before quoting.
  @instructions_bytes 400
  @description_bytes 200

  @examples """
  Role examples (examples only; design what the user asks for):
  - Frontend developer: builds and tests UI, follows the design system. claude: model sonnet, effort medium. codex: default model, effort medium.
  - Reviewer: reviews changes against the spec, reports bugs and risks, does not rewrite the code. claude: opus, high. codex: high.
  - Tester: writes and runs tests, reports failures with steps to reproduce. claude: sonnet, medium. codex: medium.
  - Architect: designs changes, writes specs, splits work into tasks (capability create_tasks). claude: opus, high. codex: high.
  - General developer: implements tasks end to end with tests. claude: sonnet, high. codex: high.
  """

  @squad_example """
  - Squad leader: reads the task, splits or delegates it to the members, checks their work and finishes the task; does not write code itself. claude: opus, high. codex: high.
  """
  @edit_explained """
  Baseline and draft: the baseline is the target's configuration when this conversation started (or at the last check); the draft is the configuration after your changes. Only the fields that differ from the baseline are written, when the user confirms. To change one field, give only it: for example propose_agent(name: "<the agent>", model: "opus") switches the model and keeps everything else. null restores a field's default; to go back to the baseline, give the baseline's value.
  """
  @identity_description_bytes 200
  @diff_bytes 8 * 1024
  @squad_description_bytes 200
  @squad_instructions_bytes 400
  @role_note_bytes 200

  @doc "The prompt of the design run `run` (its conversation read now)."
  @spec for_run(Run.t()) :: String.t()
  def for_run(%Run{} = run), do: build(Repo.get!(AgentDesign, Runs.design_id(run)), run)

  @doc "The prompt of `design`'s turn `run`; see the module documentation."
  @spec build(AgentDesign.t(), Run.t()) :: String.t()
  def build(%AgentDesign{} = design, %Run{} = run) do
    user = Repo.get!(User, design.user_id)
    workspace = Repo.get!(Workspace, design.workspace_id)

    human =
      Repo.one(
        from(a in Actor,
          where: a.workspace_id == ^workspace.id and a.user_id == ^user.id and a.kind == :human,
          select: a.name
        )
      )

    messages =
      Repo.all(from(m in AgentDesignMessage, where: m.design_id == ^design.id, order_by: m.seq))

    {current, earlier} = split_turn(messages, run.id)

    before = sections(design, user, human, workspace, current)

    last = new_message(current)
    # The history gets what the other parts leave of the whole, at most
    # its own bound; the separators and its heading fit in the margin.
    used = Enum.sum(Enum.map([last | before], &byte_size/1))
    budget = @history_bytes |> min(@prompt_bytes - used - 200) |> max(0)

    Enum.join(before ++ [history(earlier, budget), last], "\n")
  end

  # Parts 1–4 by kind (`add-edit-design-conversations` decision 11); the
  # creation kinds' parts are unchanged.
  defp sections(%AgentDesign{kind: :agent} = design, user, human, workspace, current) do
    [
      intro(user, human, workspace),
      @examples,
      options(user, workspace),
      draft(design, current)
    ]
  end

  defp sections(%AgentDesign{kind: :squad} = design, user, human, workspace, current) do
    [
      squad_intro(user, human, workspace),
      @examples <> @squad_example,
      options(user, workspace, people_and_agents(workspace, user)),
      draft(design, current) <> squad_part(design, user, workspace)
    ]
  end

  defp sections(%AgentDesign{kind: :agent_edit} = design, user, human, workspace, current) do
    {rights, owner} = Edit.rights(design)
    name = Edit.target_name(design) || design.baseline["agent"]["name"]
    readonly = Edit.readonly(design, rights)

    options =
      if rights == :owner,
        do: options(user, workspace),
        else:
          "Options for #{user.display_name}: the runtime and provider account of #{name} " <>
            "are read-only here (only its owner #{owner} can change them).\nFields:\n" <>
            Enum.map_join(Options.rules(), "", &"- #{&1}\n")

    [
      agent_edit_intro(user, human, workspace, name, owner, readonly),
      @edit_explained,
      options,
      edit_state(design, current)
    ]
  end

  defp sections(%AgentDesign{kind: :squad_edit} = design, user, human, workspace, current) do
    name = Edit.target_name(design) || design.draft["squad"]["name"]

    [
      squad_edit_intro(user, human, workspace, name),
      @edit_explained,
      options(user, workspace, people_and_agents(workspace, user)),
      edit_state(design, current) <> squad_part(design, user, workspace)
    ]
  end

  # This turn's user message and the messages before it.
  defp split_turn(messages, run_id) do
    case Enum.find(messages, &(&1.role == :user and &1.run_id == run_id)) do
      nil -> {nil, messages}
      current -> {current, Enum.filter(messages, &(&1.seq < current.seq))}
    end
  end

  defp intro(user, human, workspace) do
    who = if human, do: "#{user.display_name} (#{human})", else: user.display_name

    """
    You are helping #{who} design new managed agents for the Helmsman workspace "#{workspace.slug}". This run has no task.
    How this works:
    - You and the user talk in turns. Every turn you get the conversation so far; you keep no memory between turns.
    - Change the draft only with the Helmsman MCP tools get_design, propose_agent and withdraw_agent. You cannot create agents: the user reviews the draft and creates the agents by confirming it in the web UI, as their owner.
    - If something important is unclear, ask first. Otherwise propose, then say briefly what you chose and why.
    - Reply in the language the user writes in, in at most 3000 characters. Your final message is shown to the user.
    - Write agent instructions in English unless the user asks for another language. Instructions say who the agent is, how it works and what it must deliver; Helmsman adds the task workflow itself.
    - Never put secrets in the draft or your reply. Environment variables, extra MCP servers and CLI arguments cannot be proposed; tell the user to add them after creating the agent.
    """
  end

  defp agent_edit_intro(user, human, workspace, name, owner, readonly) do
    who = if human, do: "#{user.display_name} (#{human})", else: user.display_name

    readonly_line =
      case readonly do
        [] ->
          ""

        fields ->
          "- #{user.display_name} is not the owner: these fields are read-only and must not " <>
            "be proposed: #{Enum.join(fields, ", ")}.\n"
      end

    """
    You are helping #{who} edit the existing managed agent "#{name}" (owner: #{owner}) in the Helmsman workspace "#{workspace.slug}". This run has no task.
    How this works:
    - You and the user talk in turns. Every turn you get the conversation so far; you keep no memory between turns.
    - Change the draft only with the Helmsman MCP tools get_design and propose_agent(name: "#{name}", ...). Only the fields that differ from the baseline are written, and only after #{user.display_name} confirms on the web page.
    - You cannot rename, disable, archive or delete the agent, and you cannot change its environment, extra MCP servers or CLI arguments: if asked, tell #{user.display_name} to do it on the agent's page.
    #{readonly_line}- If something important is unclear, ask first. Otherwise propose, then say briefly what you changed and why.
    - Reply in the language the user writes in, in at most 3000 characters. Your final message is shown to the user.
    - Never put secrets in the draft or your reply.
    """
  end

  defp squad_edit_intro(user, human, workspace, name) do
    who = if human, do: "#{user.display_name} (#{human})", else: user.display_name

    """
    You are helping #{who} edit the existing squad "#{name}" of the Helmsman workspace "#{workspace.slug}": its description, instructions, leader, members and their role notes. This run has no task.
    How this works:
    - You and the user talk in turns. Every turn you get the conversation so far; you keep no memory between turns.
    - Change the draft only with the Helmsman MCP tools get_design, propose_agent, withdraw_agent and propose_squad. Only the fields that differ from the baseline are written, and the new agents created, after #{user.display_name} confirms on the web page.
    - You may propose new agents to join the squad (propose_agent, then add them with propose_squad); to change an existing member's configuration, suggest an edit conversation for that agent. You cannot rename or disable the squad: if asked, tell #{user.display_name} to do it on the squad's page.
    - If something important is unclear, ask first. Otherwise propose, then say briefly what you changed and why.
    - Reply in the language the user writes in, in at most 3000 characters. Your final message is shown to the user.
    - Never put secrets in the draft or your reply. Environment variables, extra MCP servers and CLI arguments cannot be proposed.
    """
  end

  # An edit conversation's state: the baseline, the changes against it
  # (long texts as line diffs, at most #{8} KB in all), conflicts, the new
  # agents of a squad, and the user's edits before this message.
  defp edit_state(design, current) do
    edit = Edit.present(design)

    edit_baseline(design, edit) <>
      "Changes against the baseline:\n" <>
      Changes.text(edit.changes, @diff_bytes) <>
      "\n" <>
      conflicts_text(edit.conflicts) <>
      new_agents_text(design) <>
      current_edits_text(current)
  end

  defp edit_baseline(%AgentDesign{kind: :agent_edit} = design, edit),
    do:
      "Baseline (version #{design.draft_version}):\n" <>
        agent_line(redacted(edit.baseline["agent"]))

  defp edit_baseline(%AgentDesign{kind: :squad_edit}, _edit),
    do: "Baseline: the squad as below, before your changes.\n"

  defp conflicts_text([]), do: ""

  defp conflicts_text(fields),
    do:
      "Conflicts (someone changed these on the target meanwhile; the draft keeps its own value): " <>
        Enum.join(fields, ", ") <> ".\n"

  defp new_agents_text(%AgentDesign{kind: :squad_edit} = design) do
    case Draft.agents(design.draft) do
      [] -> "New agents: none.\n"
      agents -> "New agents:\n" <> Enum.map_join(agents, "", &agent_line/1)
    end
  end

  defp new_agents_text(_design), do: ""

  defp current_edits_text(current) do
    case current && edits_text(current.edits) do
      nil -> ""
      text -> "The user changed the draft before this message: #{text}.\n"
    end
  end

  defp redacted(%{"provider_account" => %{"name" => name, "host" => host}} = entry),
    do: entry |> Map.delete("provider_account") |> Map.put("account_text", "#{name} (#{host})")

  defp redacted(entry), do: entry

  # `add-squads` decision 12: how a squad conversation works.
  defp squad_intro(user, human, workspace) do
    who = if human, do: "#{user.display_name} (#{human})", else: user.display_name

    """
    You are helping #{who} design a squad for the Helmsman workspace "#{workspace.slug}": a leader and its members, and the new managed agents it needs. This run has no task.
    How this works:
    - You and the user talk in turns. Every turn you get the conversation so far; you keep no memory between turns.
    - Change the draft only with the Helmsman MCP tools get_design, propose_agent, withdraw_agent and propose_squad. You cannot create agents or squads: the user reviews the draft and creates them by confirming it in the web UI, as their owner.
    - The leader must be a managed agent. Members can be new agents of the draft, existing managed agents of the workspace or people. One CLI and runtime can host several members, each with its own model, effort and instructions (for example a frontend developer, a reviewer and a tester).
    - When the squad runs, its leader cannot create agents or change the squad: it can only delegate work to the members or create tasks for them. Give the squad the roles it needs now.
    - If something important is unclear, ask first. Otherwise propose, then say briefly what you chose and why.
    - Reply in the language the user writes in, in at most 3000 characters. Your final message is shown to the user.
    - Write agent instructions and the squad's instructions in English unless the user asks for another language. Helmsman adds the task workflow itself.
    - Never put secrets in the draft or your reply. Environment variables, extra MCP servers and CLI arguments cannot be proposed; tell the user to add them after creating the agent.
    """
  end

  # The existing people and agents of a squad conversation, in the order
  # they are kept when the options are cut: people, the user's agents,
  # other agents.
  defp people_and_agents(workspace, user) do
    people = Enum.map(Options.people(workspace.id), &"- #{&1.name} (person)\n")

    agents =
      Options.agents(workspace.id)
      |> Enum.sort_by(&if(&1[:owner_id] == user.id, do: 0, else: 1))
      |> Enum.map(fn agent ->
        {desc, _cut?} = prefix(one_line(agent.description || ""), @identity_description_bytes)
        cli = if agent.provider, do: ", #{agent.provider}", else: ""
        "- #{agent.name} (#{agent.kind} agent#{cli}): #{desc}\n"
      end)

    people ++ agents
  end

  defp one_line(text), do: String.replace(text, ~r/[\x00-\x1F\x7F]+/u, " ")

  defp options(user, workspace), do: options_base(user, workspace) <> mcp_options(user)

  defp options_base(user, workspace) do
    runtimes = Options.runtimes(workspace.id, user.id)
    accounts = Options.accounts(user.id)
    head = "Options for #{user.display_name}:\n"
    rules = "Fields:\n" <> Enum.map_join(Options.rules(), "", &"- #{&1}\n")

    if runtimes == [] and accounts == [] do
      head <>
        "There is no runtime or provider account #{user.display_name} can bind: draft agents " <>
        "without runtime_id and tell the user to connect a daemon before using them.\n" <> rules
    else
      # Runtimes (online first), then accounts, share what the heading,
      # the rules and the notes leave of the bound.
      budget = @options_bytes - byte_size(head <> rules) - 400
      {runtimes_text, left} = lines_text(runtimes, &runtime_line/1, budget, :runtimes)
      {accounts_text, _left} = lines_text(accounts, &account_line/1, left, :accounts)
      head <> runtimes_text <> accounts_text <> rules
    end
  end

  # A squad conversation's options: the identities follow the runtimes and
  # accounts in the same 16 KB.
  defp options(user, workspace, identities),
    do: options_base(user, workspace, identities) <> mcp_options(user)

  defp options_base(user, workspace, identities) do
    runtimes = Options.runtimes(workspace.id, user.id)
    accounts = Options.accounts(user.id)
    head = "Options for #{user.display_name}:\n"
    rules = "Fields:\n" <> Enum.map_join(Options.rules(), "", &"- #{&1}\n")
    budget = @options_bytes - byte_size(head <> rules) - 600
    {runtimes_text, left} = lines_text(runtimes, &runtime_line/1, budget, :runtimes)
    {accounts_text, left} = lines_text(accounts, &account_line/1, left, :accounts)
    {identities_text, _left} = lines_text(identities, & &1, left, :identities)
    head <> runtimes_text <> accounts_text <> identities_text <> rules
  end

  defp mcp_options(user) do
    case Helmsman.McpServers.design_options(user.id) do
      [] ->
        ""

      definitions ->
        "Personal MCP definitions (choose names in mcp_servers, at most 16; never write server configurations):\n" <>
          Enum.map_join(definitions, "", fn d ->
            "- #{one_line(d.name)} (#{d.type}, #{one_line(d.program || "")})\n"
          end)
    end
  end

  defp runtime_line(runtime), do: "- " <> Options.runtime_line(runtime) <> "\n"
  defp account_line(account), do: "- #{account.id}: #{account.name} (#{account.cli})\n"

  defp lines_text([], _line, budget, :runtimes), do: {"Runtimes: none.\n", budget}
  defp lines_text([], _line, budget, :accounts), do: {"Provider accounts: none.\n", budget}

  defp lines_text([], _line, budget, :identities),
    do: {"Existing people and agents: none.\n", budget}

  defp lines_text(items, line, budget, kind) do
    {lines, left, omitted} =
      Enum.reduce(items, {[], budget, 0}, fn item, {lines, left, omitted} ->
        text = line.(item)

        if omitted == 0 and byte_size(text) <= left,
          do: {[text | lines], left - byte_size(text), 0},
          else: {lines, left, omitted + 1}
      end)

    {heading, noun} =
      case kind do
        :runtimes ->
          {"Runtimes (runtime_id):\n", "runtimes"}

        :accounts ->
          {"Provider accounts (provider_account_id; with an account the model is free text):\n",
           "provider accounts"}

        :identities ->
          {"Existing people and agents (possible members; a leader must be a managed agent):\n",
           "people and agents"}
      end

    note =
      if omitted > 0,
        do: "(#{omitted} more #{noun} omitted; call get_design for all of them)\n",
        else: ""

    {heading <> (lines |> Enum.reverse() |> Enum.join()) <> note, left}
  end

  defp draft(design, current) do
    agents = Draft.agents(design.draft)

    body =
      case agents do
        [] ->
          "Current draft (version #{design.draft_version}): empty.\n"

        _ ->
          "Current draft (version #{design.draft_version}):\n" <>
            Enum.map_join(agents, "", &agent_line/1)
      end

    case current && edits_text(current.edits) do
      nil -> body
      text -> body <> "The user changed the draft before this message: #{text}.\n"
    end
  end

  defp agent_line(%{"account_text" => text} = entry),
    do: agent_line(Map.delete(entry, "account_text"), ", provider account #{text}")

  defp agent_line(entry), do: agent_line(entry, account(entry["provider_account_id"]))

  defp agent_line(entry, account) do
    caps =
      if entry["capabilities"] in [nil, []],
        do: "none",
        else: Enum.join(entry["capabilities"], ", ")

    instructions = entry["instructions"] || ""

    "- #{entry["name"]}: #{entry["provider"]}, runtime #{entry["runtime_id"] || "none"}" <>
      account <>
      ", model #{entry["model"] || "default"}, effort #{entry["effort"] || "default"}" <>
      ", access #{entry["access"]}, capabilities #{caps}" <>
      ", limits #{entry["max_concurrency"]}/#{entry["timeout_minutes"]}/#{entry["idle_timeout_minutes"]}" <>
      ", description #{quote_excerpt(entry["description"] || "", @description_bytes)}" <>
      "; instructions #{byte_size(instructions)} bytes: " <>
      quote_excerpt(instructions, @instructions_bytes) <>
      if(byte_size(instructions) > @instructions_bytes,
        do: " (call get_design for the full text)\n",
        else: "\n"
      )
  end

  # `add-squads` decision 12: the squad part and its hint, bounded: the
  # description and every role note cut to 200 bytes, the instructions to
  # 400, each quoted (at most twice as long); at most 16 members.
  defp squad_part(design, user, workspace) do
    squad = SquadDraft.get(design.draft) || SquadDraft.empty()
    instructions = squad["instructions"] || ""

    summary =
      SquadDraft.trigger_summary(design.draft, %Helmsman.Accounts.Scope{
        user: user,
        workspace: workspace
      })

    "Squad (propose_squad): name #{squad["name"] || "not set"}, leader " <>
      "#{squad["leader"] || "not set"}, description " <>
      quote_excerpt(squad["description"] || "", @squad_description_bytes) <>
      "; instructions #{byte_size(instructions)} bytes: " <>
      quote_excerpt(instructions, @squad_instructions_bytes) <>
      "\nMembers:\n" <>
      squad_members(squad["members"]) <>
      "#{summary.able} of #{summary.total} members of the workspace can trigger the squad" <>
      restricted_text(summary.restricted) <> ". Call get_design for the full texts.\n"
  end

  defp squad_members([]), do: "  (none yet)\n"

  defp squad_members(members),
    do:
      Enum.map_join(members, "", fn m ->
        "  - #{m["name"]}: #{quote_excerpt(m["role_note"] || "", @role_note_bytes)}\n"
      end)

  defp restricted_text([]), do: ""
  defp restricted_text(names), do: "; limited by #{Enum.join(names, ", ")}"

  defp account(nil), do: ""
  defp account(id), do: ", provider account #{id}"

  # At most `max_bytes` of `text`, cut between code points (a long
  # grapheme is cut too), quoted: control characters become spaces and
  # `"` and `\\` are escaped, so the result is at most 2 * max_bytes + 5.
  defp quote_excerpt(text, max_bytes) do
    {kept, cut?} = prefix(text, max_bytes)

    escaped =
      kept
      |> String.replace(~r/[\x00-\x1F\x7F]/u, " ")
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> if(cut?, do: "…\"", else: "\"")
  end

  @doc """
  The bounded summary of `text`: at most `max_bytes` bytes, cut between
  code points (a long grapheme is cut too), so the result is always valid
  UTF-8; `true` when it was cut. Also used by `Helmsman.Runs.Prompt`
  (`add-squads` decision 7).
  """
  @spec prefix(String.t(), non_neg_integer()) :: {String.t(), boolean()}
  def prefix(text, max_bytes) when byte_size(text) <= max_bytes, do: {text, false}

  def prefix(text, max_bytes) do
    {kept, _bytes} =
      text
      |> String.codepoints()
      |> Enum.reduce_while({[], 0}, fn cp, {kept, bytes} ->
        if bytes + byte_size(cp) <= max_bytes,
          do: {:cont, {[cp | kept], bytes + byte_size(cp)}},
          else: {:halt, {kept, bytes}}
      end)

    {kept |> Enum.reverse() |> IO.iodata_to_binary(), true}
  end

  @doc """
  The edits as text: `fe-dev (model, name); removed qa; added be-dev`, or
  nil without any.
  """
  @spec edits_text([map()] | nil) :: String.t() | nil
  def edits_text(edits) when edits in [nil, []], do: nil

  def edits_text(edits) do
    Enum.map_join(edits, "; ", fn
      %{"squad" => true, "fields" => fields} ->
        "the squad (#{Enum.join(fields, ", ")})"

      %{"baseline" => fields} ->
        "someone else changed #{Enum.join(fields, ", ")} on the target (the baseline now has their values)"

      %{"removed" => true, "agent" => name} ->
        "removed #{name}"

      %{"added" => true, "agent" => name} ->
        "added #{name}"

      %{"agent" => name, "fields" => fields} ->
        "#{name} (#{Enum.join(fields, ", ")})"
    end)
  end

  defp history([], _budget), do: "Conversation so far: none; this is the first message.\n"

  defp history(messages, budget) do
    {kept, _left} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], budget - @heading_bytes}, fn message, {kept, left} ->
        text = message_text(message)

        if byte_size(text) <= left,
          do: {:cont, {[text | kept], left - byte_size(text)}},
          else: {:halt, {kept, left}}
      end)

    omitted = length(messages) - length(kept)

    head =
      if omitted > 0,
        do: "Conversation so far (#{omitted} earlier messages omitted):\n",
        else: "Conversation so far:\n"

    head <> Enum.join(kept)
  end

  defp message_text(%AgentDesignMessage{role: :user} = message) do
    edits =
      case edits_text(message.edits) do
        nil -> ""
        text -> "[user edited the draft: #{text}]\n"
      end

    edits <> "[user] #{message.content}\n"
  end

  defp message_text(%AgentDesignMessage{role: :assistant, content: content}),
    do: "[you] #{content}\n"

  defp message_text(%AgentDesignMessage{role: :system} = message),
    do: "[system] #{system_text(message.code, message.detail)}\n"

  @doc "A system message in English (`code`, `detail`)."
  @spec system_text(String.t(), String.t() | nil) :: String.t()
  def system_text("stopped", _detail), do: "The turn was stopped by the user."

  def system_text("queue_timeout", _detail),
    do: "The turn was cancelled: the helper did not start within 10 minutes (busy or offline)."

  def system_text("failed", detail), do: "The turn failed (#{detail})."
  def system_text("cancelled", nil), do: "The turn was cancelled."
  def system_text("cancelled", detail), do: "The turn was cancelled (#{detail})."
  def system_text("no_reply", _detail), do: "The turn ended without a reply."
  def system_text("helper_changed", detail), do: "The user switched the helper to #{detail}."

  def system_text("baseline_changed", detail),
    do:
      "The confirm wrote nothing: the target was changed meanwhile (#{detail}). " <>
        "The baseline now has the current values; the user must confirm again."

  def system_text("target_archived", _detail),
    do: "The conversation expired: its target was archived."

  def system_text("permission_lost", _detail),
    do: "The conversation expired: the user may no longer edit its target."

  defp new_message(nil), do: "The user's new message:\n>\n"

  defp new_message(%AgentDesignMessage{content: content}) do
    quoted = content |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
    "The user's new message:\n" <> quoted <> "\n"
  end
end
