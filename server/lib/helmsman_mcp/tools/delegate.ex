defmodule HelmsmanMCP.Tools.Delegate do
  @moduledoc """
  `delegate`: a run as a squad leader hands its task to a managed member
  of the squad (`add-squads` decision 8). Listed only for runs with the
  `delegate` capability. A delegation that is not dispatched still
  commits and is then shown as an error through `HelmsmanMCP.Rejected`.
  """

  use HelmsmanMCP.Tool,
    name: "delegate",
    description:
      "Hand this run's task to a managed member of your squad (see the squad section of " <>
        "your prompt or list_agents). The member works on the same task, branch and pull " <>
        "request after this run ends: after delegating, finish this run. You are woken with " <>
        "the member's final output when its run ends.",
    schema: %{
      task_id: {:required, :string, description: "This run's task ID (e.g. BOS-12)."},
      to: {:required, :string, description: "The member agent's name (e.g. keel/fe)."},
      instructions: {:required, :string, description: "What the member should do (at most 8 KB)."}
    },
    mode: :write

  alias Helmsman.Squads
  alias HelmsmanMCP.{Present, Rejected}

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => task_id, "to" => to} = args, %{scope: scope}) do
    case Squads.delegate(scope, task_id, to, args["instructions"]) do
      {:ok, %{result: :skipped} = skipped} ->
        {:ok, %Rejected{reason: {:delegate_not_dispatched, skipped}}}

      {:ok, %{result: result, run: run}} ->
        {:ok, %{run: Present.run(run), merged: result == :merged}}

      {:error, _reason} = error ->
        error
    end
  end
end
