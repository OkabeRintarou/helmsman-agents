defmodule HelmsmanMCP.Tools.RunAgent do
  @moduledoc """
  `run_agent`: starts a managed agent by hand (designs/13 §2.1, decision
  16). A trigger that is not dispatched still commits (it is a result, not
  a failure) and is then shown as an error through `HelmsmanMCP.Rejected`.
  """

  use HelmsmanMCP.Tool,
    name: "run_agent",
    description:
      "Start a managed agent (see list_agents), on a task or, with instructions, on none. " <>
        "If it already has a queued run on the task, your request joins it (merged: true).",
    schema: %{
      agent: {:required, :string, description: "Managed agent name (e.g. keel/dev)."},
      task_id: {:string, description: "Task ID (e.g. BOS-12) the agent should work on."},
      instructions:
        {:string,
         description: "What the agent should do (at most 8 KB; required without task_id)."}
    },
    mode: :write

  alias Helmsman.Dispatch
  alias HelmsmanMCP.{Present, Rejected}

  @impl HelmsmanMCP.Tool
  def call(%{"agent" => agent} = args, %{scope: scope}) do
    case Dispatch.run_agent(scope, agent, args["task_id"], args["instructions"]) do
      {:ok, %{outcome: %{result: :skipped, reason: reason}}} ->
        {:ok, %Rejected{reason: {:not_dispatched, reason}}}

      {:ok, %{outcome: outcome, run: run}} ->
        {:ok, %{run: Present.run(run), merged: outcome.result == :merged}}

      {:error, _reason} = error ->
        error
    end
  end
end
