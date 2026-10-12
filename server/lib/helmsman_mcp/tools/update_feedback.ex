defmodule HelmsmanMCP.Tools.UpdateFeedback do
  @moduledoc "`update_feedback`: revises a feedback record."

  use HelmsmanMCP.Tool,
    name: "update_feedback",
    description:
      "Revise a feedback record written by you or your own agents: a new record takes " <>
        "its place and the old one is kept as superseded. Only the current version can " <>
        "be revised.",
    schema: %{
      feedback_id: {:required, :string, description: "Feedback ID (e.g. BOS-12#3)."},
      content: {:required, :string, description: "New Markdown content."},
      kind: {:string, description: "New kind; the old one by default."},
      author: HelmsmanMCP.Tool.author_field()
    },
    mode: :write

  alias Helmsman.Feedback
  alias HelmsmanMCP.{Args, Present}

  @impl HelmsmanMCP.Tool
  def call(%{"feedback_id" => id} = args, %{scope: scope}) do
    with {:ok, entry} <- Feedback.revise(scope, id, Args.take(args, [:kind, :content])) do
      {:ok, Present.feedback(Feedback.view(entry))}
    end
  end
end
