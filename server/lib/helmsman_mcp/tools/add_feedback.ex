defmodule HelmsmanMCP.Tools.AddFeedback do
  @moduledoc "`add_feedback`: adds a feedback record to a task."

  use HelmsmanMCP.Tool,
    name: "add_feedback",
    description:
      "Add feedback to a task: comment (default), review, question or answer. Records " <>
        "are immutable; use update_feedback to revise. After a question, stop and wait " <>
        "for the answer. dispatch lists what the record triggered; a mention skipped with " <>
        "reason covered was not run because the same record's answer or callback already " <>
        "woke that agent.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      content: {:required, :string, description: "Markdown, at most 64 KB."},
      kind: {:string, description: "comment (default), review, question or answer."},
      reply_to: {:string, description: "Feedback ID to reply to, in this task (e.g. BOS-12#3)."},
      author: HelmsmanMCP.Tool.author_field()
    },
    mode: :write

  alias Helmsman.Feedback
  alias HelmsmanMCP.{Args, Present}

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id} = args, %{scope: scope}) do
    with {:ok, entry} <- Feedback.add(scope, id, Args.take(args, [:kind, :content, :reply_to])) do
      {:ok, Present.feedback(Feedback.view(entry))}
    end
  end
end
