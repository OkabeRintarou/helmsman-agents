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
        true -> "Not found in workspace #{scope.workspace.slug}."
      end

    {:ok, text}
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

  def format({:self_verify_requires_tests, name}, _ctx) do
    you = if is_binary(name), do: "You (#{name})", else: "You"

    {:ok, "#{you} are the assignee. Pass tests={passed: true, ...} or let the requester verify."}
  end

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

  def format(%Ecto.Changeset{} = changeset, _ctx) do
    text =
      changeset
      |> Ecto.Changeset.traverse_errors(&interpolate/1)
      |> Enum.sort()
      |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
      |> Enum.join("\n")

    {:ok, text}
  end

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
