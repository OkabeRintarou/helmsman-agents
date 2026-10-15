defmodule HelmsmanMCP.ErrorText do
  @moduledoc """
  The English texts tool errors are shown to agents as (designs/08 §5):
  what went wrong and what to do next. Changes that add tools add their
  clauses here.
  """

  alias HelmsmanMCP.Context

  @doc """
  Returns the text of a domain error, or `:error` for a reason without a
  clause (the pipeline then answers with `internal/1`).
  """
  @spec format(term(), Context.t()) :: {:ok, String.t()} | :error
  # `add-spec-workflow` decision 20.
  def format(reason, ctx) when is_tuple(reason) and elem(reason, 0) == :spec,
    do: HelmsmanMCP.SpecErrorText.format(reason, ctx)

  def format(:bql_or_filter, _ctx), do: {:ok, "Pass either bql or filter_id."}

  def format(:no_identity, %Context{tool: "query_tasks"}),
    do: {:ok, "currentUser() needs an identity; call identify first."}

  def format(:query_timeout, _ctx),
    do: {:ok, "The query took too long; narrow it down (e.g. add project = KEY)."}

  def format({:invalid_bql, %{message: message, position: position}}, _ctx) do
    fields =
      if String.starts_with?(message, "unknown field"),
        do:
          " Available fields: " <>
            Enum.map_join(Helmsman.BQL.fields(), ", ", &to_string(&1.name)) <> ".",
        else: ""

    {:ok, "Invalid BQL at position #{position}: #{message}" <> fields}
  end

  def format({:invalid, field}, %Context{tool: "query_tasks"}) when field in [:limit, :offset],
    do: {:ok, "Invalid #{field}; use limit 1–200 and offset 0–10000."}

  def format({:forbidden, {:cancels_other_task, replaced, own}}, _ctx) do
    {:ok,
     "This run cannot replace #{replaced}: it would cancel a task other than #{own}. " <>
       "Ask a person to do it."}
  end

  # `add-agent-conversation` decision 7: the draft tools.
  def format({:design, :not_design_run}, %Context{tool: tool}),
    do: {:ok, "#{tool} is only available in agent design runs."}

  def format({:design, :turn_ended}, _ctx) do
    {:ok,
     "This design turn has ended (the user stopped it, changed the draft or closed the " <>
       "conversation). The draft was not changed; end your reply."}
  end

  # `add-squads` decision 12.
  def format({:design, :not_squad}, _ctx),
    do: {:ok, "This is not a squad conversation: propose_squad is not available."}

  def format({:referenced_by_squad, name}, _ctx) do
    {:ok,
     "#{name} is the leader or a member of the draft's squad. Change the squad first " <>
       "(propose_squad), then remove it."}
  end

  def format({:invalid_squad, %Ecto.Changeset{} = changeset}, _ctx) do
    lines =
      changeset.errors
      |> Enum.map(fn {field, error} -> "#{field}: #{interpolate(error)}" end)
      |> Enum.uniq()

    {:ok,
     "The squad was not changed in the draft. Fix these fields and call propose_squad " <>
       "again:\n" <> Enum.join(lines, "\n")}
  end

  def format(:draft_full, _ctx) do
    {:ok,
     "The draft already has #{Helmsman.AgentDesigns.max_agents()} agents. " <>
       "Withdraw one (withdraw_agent) before proposing another."}
  end

  def format({:invalid_agent, name, %Ecto.Changeset{} = changeset}, _ctx) do
    lines =
      changeset.errors
      |> Enum.map(fn {field, {message, opts}} ->
        supported =
          case opts[:supported] do
            [_ | _] = values -> " (supported: #{Enum.join(values, ", ")})"
            _none -> ""
          end

        "#{field}: #{interpolate({message, opts})}#{supported}"
      end)
      |> Enum.uniq()

    {:ok,
     "#{name || "The agent"} was not changed in the draft. Fix these fields and call " <>
       "propose_agent again:\n" <> Enum.join(lines, "\n")}
  end

  def format({:not_in_draft, name}, _ctx),
    do: {:ok, "#{name} is not in the draft; get_design lists its agents."}

  # spec-tools 「请求评审工具」.
  def format(:forbidden, %Context{tool: "request_spec_review", scope: %{via: :run}}) do
    {:ok,
     "A run cannot request spec reviews. As the squad leader, use delegate(task_id, to, " <>
       "instructions, spec: \"review\"); otherwise mention the reviewer (@name) in a " <>
       "feedback comment and ask the coordinator."}
  end

  def format(:forbidden, %Context{scope: %{via: :run, run: run}}) do
    caps = Enum.join(run.capabilities, ", ")

    change =
      case run.task do
        %{ident: ident} -> " and change #{ident}"
        _none -> ""
      end

    {:ok,
     "This run can only read the workspace#{change} (capabilities: #{caps}). " <>
       "Ask a human to do anything else."}
  end

  def format(:forbidden, %Context{tool: "update_feedback", scope: %{role: role}} = ctx)
      when role not in [nil, :viewer] do
    {:ok,
     "You can only revise feedback written by you or your own agents. " <>
       "Add a new feedback instead." <> writer_hint(ctx)}
  end

  def format(:forbidden, %Context{} = ctx) do
    text =
      case ctx.scope.role do
        nil -> "You cannot do this."
        role -> "Your role (#{role}) cannot do this."
      end

    {:ok, text <> writer_hint(ctx)}
  end

  def format(:not_found, %Context{scope: scope, args: args}) do
    where = "not found in workspace #{scope.workspace.slug}."

    text =
      cond do
        id = arg(args, "feedback_id") -> "Feedback #{id} #{where}"
        id = arg(args, "task_id") -> "Task #{id} #{where}"
        key = arg(args, "project_key") || arg(args, "key") -> "Project #{key} #{where}"
        is_integer(args["run_id"]) -> "Run #{args["run_id"]} #{where}"
        true -> "Not found in workspace #{scope.workspace.slug}."
      end

    {:ok, text}
  end

  def format({:not_found, ident}, %Context{scope: scope}) when is_binary(ident),
    do: {:ok, "Task #{ident} not found in workspace #{scope.workspace.slug}."}

  def format({:cycle, [from, to | _] = path}, _ctx) do
    {:ok,
     "Cannot make #{from} depend on #{to}: it would create the cycle " <>
       "#{Enum.join(path, " → ")}."}
  end

  def format(:self_link, _ctx), do: {:ok, "A task cannot be linked to itself."}

  def format({:invalid_type, input}, _ctx),
    do: {:ok, "Unknown link type \"#{value(input)}\". Use depends_on or replaces."}

  def format({:blocked, blockers}, %Context{args: args}) do
    {:ok,
     "#{arg(args, "task_id") || "The task"} is blocked by #{Enum.join(blockers, ", ")} " <>
       "(not finished yet). Finish them first, or unlink_tasks if the dependency is wrong."}
  end

  def format({:replaced, [replacer]}, %Context{args: args}) do
    ident = arg(args, "task_id") || "The task"

    {:ok,
     "#{ident} was replaced by #{replacer}. unlink_tasks(#{replacer}, #{ident}, replaces) " <>
       "first if it really needs to come back."}
  end

  def format({:replaced, replacers}, %Context{args: args}) do
    ident = arg(args, "task_id") || "The task"

    {:ok,
     "#{ident} was replaced by #{Enum.join(replacers, ", ")}. Remove each link with " <>
       "unlink_tasks(<replacer>, #{ident}, replaces) first if it really needs to come back."}
  end

  def format({:invalid_transition, from, to, allowed}, %Context{args: args}) do
    {:ok,
     "Cannot move #{arg(args, "task_id") || "the task"} from #{status(from)} to " <>
       "#{status(to)}. Allowed: #{Enum.map_join(allowed, ", ", &status/1)}."}
  end

  def format({:invalid_status, input, valid}, _ctx) do
    {:ok,
     "Unknown status #{inspect(input)}. Use one of: #{Enum.map_join(valid, ", ", &status/1)}."}
  end

  # `add-squads` decision 11: on the assignee side of a squad's task.
  def format({:self_verify_requires_tests, name}, %Context{scope: %{workspace: %{id: ws}}} = ctx)
      when is_binary(name) and is_integer(ws) do
    if Helmsman.Squads.squad_name?(ws, name) do
      {:ok,
       "You are on the assignee side of #{arg(ctx.args, "task_id") || "the task"} " <>
         "(squad #{name}). Pass tests={passed: true, ...} or let the requester verify."}
    else
      {:ok,
       "You (#{name}) are the assignee. Pass tests={passed: true, ...} or let the requester " <>
         "verify."}
    end
  end

  def format({:self_verify_requires_tests, name}, _ctx) do
    you = if is_binary(name), do: "You (#{name})", else: "You"

    {:ok, "#{you} are the assignee. Pass tests={passed: true, ...} or let the requester verify."}
  end

  def format(:busy, %Context{args: args}) do
    ident =
      arg(args, "task_id") ||
        case arg(args, "feedback_id") do
          id when is_binary(id) -> id |> String.split("#") |> hd()
          nil -> "the task"
        end

    {:ok, "Too many concurrent changes to #{ident}; try again."}
  end

  def format(:stale, %Context{tool: "save_filter"}),
    do:
      {:ok,
       "The filter was changed by someone else since you read it. Call list_filters for the latest lock_version, then retry."}

  def format(:stale, %Context{args: args}) do
    {:ok,
     "#{arg(args, "task_id") || "The task"} was changed by someone else since you read it. " <>
       "Call get_task to see the latest version (lock_version), then retry."}
  end

  def format(:project_archived, %Context{args: args}) do
    {:ok,
     "Project #{arg(args, "project_key") || arg(args, "key")} is archived and cannot take " <>
       "new tasks. An admin can restore it with update_project(archived: false)."}
  end

  def format({:superseded, latest_id}, %Context{args: args}) do
    {:ok,
     "#{arg(args, "feedback_id") || "This feedback"} was already revised; the current " <>
       "version is #{latest_id}. Revise that one instead."}
  end

  def format({:invalid_commits, bad}, _ctx) do
    {:ok, "Invalid commit hashes: #{value(bad)}. Each must be 7-64 hexadecimal characters."}
  end

  def format({:invalid_tests, reason}, _ctx) do
    {:ok, "Invalid tests: #{tests_reason(reason)}. Pass {command, passed: true/false, summary}."}
  end

  def format({:invalid_comment, :too_long}, _ctx) do
    {:ok, "comment is too long (max 10000 characters). Put details in a feedback instead."}
  end

  def format({:invalid_comment, _reason}, _ctx), do: {:ok, "comment must be a string."}

  def format({:invalid_feedback, _reason}, _ctx),
    do: {:ok, "feedback must be an object: {kind, content}."}

  def format(reason, _ctx) when reason in [:no_identity, :no_actor] do
    {:ok, "You have no identity in this session. Call identify(name, project, worktree) first."}
  end

  def format(:name_taken, %Context{args: args}) do
    name = with name when is_binary(name) <- args["name"], do: " #{name}"

    {:ok,
     "The name#{name} belongs to a human or to someone else's agent. " <>
       "Pick another agent name, such as team/role (e.g. keel/dev)."}
  end

  def format(:agent_disabled, %Context{args: args} = ctx),
    do: format({:agent_disabled, args["name"]}, ctx)

  def format({:agent_disabled, name}, _ctx) do
    subject = if is_binary(name), do: "The agent #{name}", else: "This agent"

    {:ok,
     "#{subject} is disabled. Call identify with another agent name, " <>
       "or ask a human to enable it."}
  end

  def format({:invalid_kind, _kind}, _ctx), do: {:ok, "Only kind=agent is supported."}

  def format(:run_ended, _ctx),
    do: {:ok, "This run has ended; its token is no longer valid. Nothing was written."}

  def format(:not_managed, %Context{args: args}) do
    {:ok,
     "#{args["agent"] || "This agent"} is an external agent: only managed agents can be " <>
       "started. Pick a managed agent from list_agents."}
  end

  # `add-squads` decision 4.
  def format(:is_squad, %Context{args: args}) do
    name = args["agent"] || "This identity"

    {:ok, "#{name} is a squad; assign the task to it or mention @#{name} instead."}
  end

  def format(:instructions_required, %Context{tool: "delegate"}),
    do: {:ok, "Give the member instructions: what to do in its run."}

  def format(:instructions_required, _ctx) do
    {:ok, "Give instructions when you start an agent without a task (task_id)."}
  end

  def format({:invalid_instructions, :too_long}, _ctx),
    do: {:ok, "instructions are too long (max 8 KB). Put details in the task instead."}

  def format({:invalid_instructions, _reason}, _ctx), do: {:ok, "instructions must be a string."}

  def format(:already_finished, %Context{args: args}) do
    {:ok, "Run #{args["run_id"] || ""} has already ended; there is nothing to stop."}
  end

  # `Helmsman.Runs.Retry.retry/2`, reached by REST (`add-rest-api`
  # decision 7).
  def format(:not_ended, _ctx),
    do: {:ok, "Only a failed or cancelled run can be retried."}

  def format(:not_retryable, _ctx),
    do: {:ok, "This run cannot be retried (a design run: send the turn again instead)."}

  def format(reason, _ctx) when reason in [:agent_archived, :no_runtime, :runtime_disabled],
    do: {:ok, "The run cannot be retried: #{not_dispatched(reason)}."}

  def format(:rate_limited, _ctx),
    do: {:ok, "The run cannot be retried: #{not_dispatched(:rate_limited)}."}

  def format({:already_retried, id}, _ctx) do
    {:ok, "This run was already retried by run #{id}. Look at that run instead (list_runs)."}
  end

  def format(:task_closed, %Context{args: args}) do
    {:ok,
     "#{arg(args, "task_id") || "The task"} is verified or cancelled: no agent can be " <>
       "started on it. Reopen it first, or create a new task."}
  end

  # `add-squads` decision 8: `delegate`.
  def format({:delegate, :task_closed, ident}, _ctx),
    do: {:ok, "#{ident} is not new or in progress: there is nothing to delegate."}

  def format({:delegate, :not_squad_task, squad}, %Context{args: args}) do
    {:ok,
     "#{arg(args, "task_id") || "This task"} is no longer assigned to your squad #{squad}; " <>
       "you can only delegate your squad's task. End this run."}
  end

  def format({:delegate, :squad_disabled, squad}, _ctx),
    do: {:ok, "The squad #{squad} is disabled: nothing can be delegated. End this run."}

  def format({:delegate, :not_leader, squad}, _ctx),
    do: {:ok, "You no longer lead the squad #{squad}: you cannot delegate. End this run."}

  def format({:delegate, :not_member, {squad, names}}, %Context{args: args}) do
    can =
      case names do
        [] -> "No member agent can be delegated now."
        names -> "You can delegate to: #{Enum.join(names, ", ")}."
      end

    {:ok, "#{args["to"] || "That agent"} is not a member agent of the squad #{squad}. " <> can}
  end

  def format({:delegate, :person_member, name}, _ctx) do
    {:ok,
     "#{name} is a person in the squad and cannot be delegated a run. When you need their " <>
       "decision, write a question on the task with add_feedback (kind \"question\")."}
  end

  def format({:delegate_not_dispatched, %{reason: :unauthorized} = skipped}, _ctx) do
    {:ok,
     "cannot_invoke: #{skipped.initiator || "the person this run acts for"} may not trigger " <>
       "#{skipped.member}. Pick another member, or say so in a question on the task."}
  end

  def format({:delegate_not_dispatched, %{reason: reason, member: member}}, _ctx),
    do: {:ok, "#{member} was not started: #{not_dispatched(reason)}."}

  def format({:not_dispatched, reason}, %Context{args: args}) do
    {:ok, "#{args["agent"] || "The agent"} was not started: #{not_dispatched(reason)}."}
  end

  def format({:run_active, %{id: id, agent: agent}}, %Context{args: args}) do
    {:ok,
     "#{arg(args, "task_id") || "The task"} cannot be verified while #{agent} is still " <>
       "running on it (run #{id}). Wait until the run ends and its changes are pushed."}
  end

  def format({:invalid_query, :too_long}, _ctx),
    do: {:ok, "The query is too long (at most 200 characters)."}

  def format({:invalid_query, :not_a_string}, _ctx), do: {:ok, "query must be a string."}

  def format({:invalid, :kind}, %Context{args: args}) do
    {:ok, "Unknown kind #{inspect(args["kind"])}. Use task or epic."}
  end

  def format(%Ecto.Changeset{} = changeset, _ctx) do
    text =
      changeset
      |> Ecto.Changeset.traverse_errors(&interpolate/1)
      |> Enum.sort()
      |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
      |> Enum.join("\n")

    {:ok, text}
  end

  def format({:invalid_import, errors}, _ctx),
    do: {:ok, "Invalid snapshot: #{inspect(errors)}"}

  def format({code, detail}, _ctx)
      when code in [:diverged, :actor_kind_conflict, :replace_blocked, :cycle],
      do: {:ok, "#{code}: #{inspect(detail)}"}

  def format(reason, _ctx)
      when reason in [:invalid_params, :confirmation_required, :too_large, :storage_unavailable],
      do: {:ok, "Backup request failed: #{reason}."}

  def format(_reason, _ctx), do: :error

  @doc "The text of a tool call whose token stopped being valid."
  @spec unauthorized() :: String.t()
  def unauthorized,
    do:
      "Your API token is no longer valid for this session (revoked, expired or you left " <>
        "the workspace). Reconnect with a valid token."

  @doc "The text of an unexpected failure, with its log reference."
  @spec internal(String.t()) :: String.t()
  def internal(ref),
    do: "Internal error (ref #{ref}). Try again later; if it keeps happening, tell a human."

  defp writer_hint(%Context{args: args}) do
    case Enum.find(["actor", "author"], &Map.has_key?(args, &1)) do
      nil -> ""
      key -> " The #{key} argument must name an agent of your own."
    end
  end

  # An ID argument as given, upper case (IDs are case-insensitive).
  defp arg(args, key) do
    case args[key] do
      value when is_binary(value) and value != "" -> String.upcase(value)
      _ -> nil
    end
  end

  defp status(status) when is_atom(status), do: status |> Atom.to_string() |> String.upcase()
  defp status(status), do: status |> to_string() |> String.upcase()

  defp value(value) when is_binary(value), do: value
  defp value(value), do: inspect(value)

  defp not_dispatched(:unauthorized),
    do:
      "you are unauthorized to trigger it (its owner limits who can run it); ask its owner, " <>
        "or pick another agent from list_agents"

  defp not_dispatched(:agent_disabled), do: "it is disabled; ask its owner to enable it"
  defp not_dispatched(:agent_archived), do: "it is archived"

  defp not_dispatched(:no_runtime),
    do: "it is not bound to a runtime; its owner must bind one in its settings"

  defp not_dispatched(:runtime_disabled), do: "its runtime is disabled"
  defp not_dispatched(:task_closed), do: "the task is closed"
  defp not_dispatched(:not_started), do: "the request asked not to start it"

  defp not_dispatched(:loop_detected),
    do: "it is already in the trigger chain (agents may not trigger each other in a loop)"

  defp not_dispatched(:chain_too_long), do: "the trigger chain is longer than 5 agents"

  defp not_dispatched(:rate_limited),
    do: "too many runs were started on this task in the last hour; try again later"

  defp not_dispatched(reason), do: to_string(reason)

  defp tests_reason(:not_an_object), do: "tests must be an object"
  defp tests_reason({:passed, _}), do: "passed must be true or false"
  defp tests_reason({key, :too_long}), do: "#{key} is longer than 2000 characters"
  defp tests_reason({key, :not_a_string}), do: "#{key} must be a string"
  defp tests_reason(reason), do: inspect(reason)

  defp interpolate({message, opts}) do
    Regex.replace(~r/%\{(\w+)\}/, message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
