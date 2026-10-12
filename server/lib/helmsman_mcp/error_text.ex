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
  def format(:forbidden, %Context{} = ctx) do
    text =
      case ctx.scope.role do
        nil -> "You cannot do this."
        role -> "Your role (#{role}) cannot do this."
      end

    if Map.has_key?(ctx.args, "actor"),
      do: {:ok, text <> " The actor argument must name an agent of your own."},
      else: {:ok, text}
  end

  def format(:not_found, %Context{scope: scope}),
    do: {:ok, "Not found in workspace #{scope.workspace.slug}."}

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

  defp interpolate({message, opts}) do
    Regex.replace(~r/%\{(\w+)\}/, message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
