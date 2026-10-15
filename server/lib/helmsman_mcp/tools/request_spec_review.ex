defmodule HelmsmanMCP.Tools.RequestSpecReview do
  @moduledoc """
  `request_spec_review`: asks reviewers to review the latest version of a
  task's spec; a managed agent gets a review run. Not listed for run
  tokens (runs use `delegate(spec: "review")` or a mention).
  """

  use HelmsmanMCP.Tool,
    name: "request_spec_review",
    description:
      "Ask people or agents to review the latest version of a task's spec. A managed agent " <>
        "starts a review run; a reviewer who already has a pending request keeps it. " <>
        "Returns each reviewer's request and what was started.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      reviewers:
        {:required, {:list, :string}, description: "Reviewer names (e.g. [\"keel/review\"])."},
      instructions: {:string, description: "What to look at (at most 8 KB)."}
    },
    mode: :write

  alias Helmsman.TaskSpecs

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id, "reviewers" => reviewers} = args, %{scope: scope}),
    do: TaskSpecs.request_reviews(scope, id, reviewers, %{note: args["instructions"]})
end
