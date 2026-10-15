defmodule HelmsmanMCP.OrchestrationErrorText do
  @moduledoc """
  The texts of the orchestration errors `{:orchestration, reason, ...}`
  (`improve-squad-leader-orchestration` decision 16), called by
  `HelmsmanMCP.ErrorText.format/2`.
  """

  alias Helmsman.Squads
  alias HelmsmanMCP.{Context, ErrorText}

  @doc "The text of an orchestration error, or `:error`."
  @spec format(tuple(), Context.t()) :: {:ok, String.t()} | :error
  def format({:orchestration, :outside, ident, nil}, _ctx) do
    {:ok,
     "#{ident} is not part of a task you lead in this run. You may only orchestrate the " <>
       "steps of the epic or task your squad owns and the tasks your squad created for it."}
  end

  def format({:orchestration, :outside, ident, root}, _ctx) do
    {:ok,
     "#{ident} is not part of #{root}, which you lead in this run. You may only orchestrate " <>
       "its steps and the tasks your squad created for it."}
  end

  def format({:orchestration, :root, ident}, _ctx) do
    {:ok,
     "#{ident} is the task you lead; you cannot reassign or start it. Change it from a run " <>
       "on #{ident}, or ask a person."}
  end

  def format({:orchestration, :fields, allowed}, ctx) do
    {:ok,
     "When orchestrating #{task(ctx)} you may only change #{Enum.join(allowed, " and ")}. " <>
       "Put guidance in start_task instructions instead."}
  end

  def format({:orchestration, :outside_assignee, ident, name}, ctx) do
    {:ok,
     "#{ident} is assigned to #{name}, who is not in #{squad(ctx)}. Ask a person to " <>
       "reassign it."}
  end

  def format({:orchestration, :not_member, name, squad}, _ctx) do
    {:ok,
     "#{name} is not a member of #{squad}. Assign the task to a member (see the Squad " <>
       "section) or leave it unassigned."}
  end

  def format({:orchestration, :no_assignee, ident}, _ctx) do
    {:ok, "#{ident} has no assignee. Assign it with update_task(task_id, assignee, start: true)."}
  end

  def format({:orchestration, :person_assignee, ident, name}, _ctx) do
    {:ok,
     "#{ident} is assigned to #{name}, a person; Helmsman cannot start people. Write a " <>
       "question if you need #{name}, or reassign the task."}
  end

  def format({:orchestration, :not_managed, ident, name}, _ctx) do
    {:ok,
     "#{ident} is assigned to #{name}, which Helmsman does not run (not a managed agent). " <>
       "Reassign it to a member agent, or ask a person."}
  end

  def format({:orchestration, :link_type}, _ctx),
    do: {:ok, "When orchestrating you may only add or remove depends_on links."}

  def format({:orchestration, reason, squad}, ctx) when reason in [:not_leader, :squad_disabled],
    do: ErrorText.format({:delegate, reason, squad}, ctx)

  def format(_reason, _ctx), do: :error

  defp task(%Context{args: args}), do: args["task_id"] || "the task"

  defp squad(%Context{scope: %{run: %{squad_id: id}}}) when is_integer(id) do
    case Squads.load(id) do
      %{actor: actor} -> actor.name
      nil -> "your squad"
    end
  end

  defp squad(_ctx), do: "your squad"
end
