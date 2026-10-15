defmodule HelmsmanMCP.Tools.StartTask do
  @moduledoc """
  `start_task`: an orchestrating run starts the assignee of a task it
  orchestrates (`improve-squad-leader-orchestration` decision 5). Listed
  only for runs with the `orchestrate` capability. A start that is not
  dispatched still commits and comes back as a result.
  """

  use HelmsmanMCP.Tool,
    name: "start_task",
    description:
      "Start the assignee (a member agent of your squad) of a task you orchestrate (see the " <>
        "Orchestration section of your prompt), with optional instructions. The start waits " <>
        "for unfinished prerequisites (result deferred) and does nothing when the assignee " <>
        "already has a pending or active run there (result already). Give a task without an " <>
        "assignee to a member with update_task(task_id, assignee, start: true) instead.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. ACC-12)."},
      instructions:
        {:string, description: "What the member should do (at most 8 KB), quoted in its prompt."}
    },
    mode: :write

  alias Helmsman.Squads
  alias HelmsmanMCP.Present

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id} = args, %{scope: scope}) do
    with {:ok, result} <- Squads.start_task(scope, id, args["instructions"]) do
      {:ok, Map.update(result, :run, nil, &(&1 && Present.run(&1)))}
    end
  end
end
