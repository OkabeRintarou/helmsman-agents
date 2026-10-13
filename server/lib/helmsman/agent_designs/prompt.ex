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
  alias Helmsman.AgentDesigns.{AgentDesign, AgentDesignMessage, Draft, Options}
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

    before = [
      intro(user, human, workspace),
      @examples,
      options(user, workspace),
      draft(design, current)
    ]

    last = new_message(current)
    # The history gets what the other parts leave of the whole, at most
    # its own bound; the separators and its heading fit in the margin.
    used = Enum.sum(Enum.map([last | before], &byte_size/1))
    budget = @history_bytes |> min(@prompt_bytes - used - 200) |> max(0)

    Enum.join(before ++ [history(earlier, budget), last], "\n")
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

  defp options(user, workspace) do
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

  defp runtime_line(runtime), do: "- " <> Options.runtime_line(runtime) <> "\n"
  defp account_line(account), do: "- #{account.id}: #{account.name} (#{account.cli})\n"

  defp lines_text([], _line, budget, :runtimes), do: {"Runtimes: none.\n", budget}
  defp lines_text([], _line, budget, :accounts), do: {"Provider accounts: none.\n", budget}

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

  defp agent_line(entry) do
    caps =
      if entry["capabilities"] in [nil, []],
        do: "none",
        else: Enum.join(entry["capabilities"], ", ")

    instructions = entry["instructions"] || ""

    "- #{entry["name"]}: #{entry["provider"]}, runtime #{entry["runtime_id"] || "none"}" <>
      account(entry["provider_account_id"]) <>
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

  defp prefix(text, max_bytes) when byte_size(text) <= max_bytes, do: {text, false}

  defp prefix(text, max_bytes) do
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
      %{"removed" => true, "agent" => name} -> "removed #{name}"
      %{"added" => true, "agent" => name} -> "added #{name}"
      %{"agent" => name, "fields" => fields} -> "#{name} (#{Enum.join(fields, ", ")})"
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

  defp new_message(nil), do: "The user's new message:\n>\n"

  defp new_message(%AgentDesignMessage{content: content}) do
    quoted = content |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
    "The user's new message:\n" <> quoted <> "\n"
  end
end
