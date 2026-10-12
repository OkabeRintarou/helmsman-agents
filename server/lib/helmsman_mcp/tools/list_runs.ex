defmodule HelmsmanMCP.Tools.ListRuns do
  @moduledoc "`list_runs`: the runs of a task."

  use HelmsmanMCP.Tool,
    name: "list_runs",
    description:
      "List the runs of a task, newest first: agent, status (QUEUED, RUNNING, ...), why it " <>
        "was started (triggers) and when.",
    schema: %{task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."}},
    mode: :read

  alias Helmsman.Runs
  alias HelmsmanMCP.Present

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id}, %{scope: scope}) do
    with {:ok, runs} <- Runs.list_for_task(scope, id),
         do: {:ok, %{runs: Enum.map(runs, &Present.run/1)}}
  end
end
