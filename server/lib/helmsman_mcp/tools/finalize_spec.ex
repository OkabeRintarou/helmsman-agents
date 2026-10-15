defmodule HelmsmanMCP.Tools.FinalizeSpec do
  @moduledoc "`finalize_spec`: finalizes, approves or proposes a version of a task's spec."

  use HelmsmanMCP.Tool,
    name: "finalize_spec",
    description:
      "Finalize the latest version of a task's spec once it passes validation, every " <>
        "review request is done and no P1/P2 issue is open or disputed. A person finalizes " <>
        "(or approves the proposal); the squad leader finalizes when the squad decides " <>
        "itself, else proposes it for a person's approval (pending_approval). Returns the " <>
        "spec's new status.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      version: {:required, :integer, description: "The latest version."},
      summary:
        {:string,
         description:
           "What the spec settles, for the approver (required for agents, at most 16 KB)."},
      wake:
        {:boolean,
         description: "A person only: wake the assignee with the decision (default true)."}
    },
    mode: :write

  alias Helmsman.TaskSpecs
  alias HelmsmanMCP.{Args, SpecPresent}

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id} = args, %{scope: scope}) do
    with {:ok, result} <-
           TaskSpecs.finalize(scope, id, Args.take(args, [:version, :summary, :wake])) do
      {:ok,
       %{
         status: result.spec.status,
         decision: result.decision,
         spec: SpecPresent.summary(result.spec),
         dispatch: result.dispatch
       }}
    end
  end
end
