defmodule HelmsmanMCP.Tools.TransitionTask do
  @moduledoc "`transition_task`: moves a task to another status."

  use HelmsmanMCP.Tool,
    name: "transition_task",
    description:
      "Move a task to another status (case-insensitive). NEW -> IN_PROGRESS claims an " <>
        "unassigned task for you. Finish with DONE plus commits and tests. If you are the " <>
        "assignee, VERIFIED needs tests with passed: true. feedback records the reason " <>
        "(e.g. a review when sending work back). Returns the task.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      to:
        {:required, :string,
         description: "NEW, IN_PROGRESS, DONE, VERIFIED, REJECTED or CANCELLED."},
      comment: {:string, description: "Short note, at most 10000 characters."},
      commits: {:list, :string, description: "Commit hashes, 7-64 hexadecimal characters each."},
      tests:
        {:object,
         %{
           command: {:string, description: "The test command run."},
           passed: {:required, :boolean, description: "Whether the tests passed."},
           summary: {:string, description: "Result summary (e.g. 12 tests, 0 failures)."}
         }, description: "The test result."},
      feedback:
        {:object,
         %{
           kind: {:string, description: "comment (default), review, question or answer."},
           content: {:required, :string, description: "Markdown."}
         }, description: "The reason, saved as feedback with the transition."}
    },
    mode: :write

  alias Helmsman.Tasks
  alias HelmsmanMCP.{Args, Present}

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id, "to" => to} = args, %{scope: scope}) do
    opts = Args.take(args, [:comment, :commits, :tests, :feedback])

    with {:ok, detail} <- Tasks.transition(scope, id, to, opts),
         do: {:ok, detail |> Present.detail() |> Present.put_dispatch(detail.dispatch)}
  end
end
