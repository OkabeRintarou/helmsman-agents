defmodule HelmsmanMCP.Tools.SubmitSpecReview do
  @moduledoc "`submit_spec_review`: a review of the latest version of a task's spec."

  use HelmsmanMCP.Tool,
    name: "submit_spec_review",
    description:
      "Review the latest version of a task's spec: verdict pass, fail or comment, a summary " <>
        "and issues (P1 blocks, P2 must be resolved, P3 is a suggestion). You cannot review " <>
        "a version you wrote. Returns the review number and the issue IDs (R<review>.<n>).",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      version: {:required, :integer, description: "The version you reviewed (the latest)."},
      verdict: {:required, :string, description: "pass, fail or comment."},
      summary: {:required, :string, description: "The review (Markdown, at most 16 KB)."},
      issues:
        {:list,
         {:object,
          %{
            severity: {:required, :string, description: "P1, P2 or P3."},
            file: {:string, description: "The file (e.g. specs/settings/spec.md)."},
            line: {:integer, description: "The line in the file."},
            anchor: {:string, description: "A heading or phrase to find the place."},
            body: {:required, :string, description: "The problem."},
            suggestion: {:string, description: "How to fix it."}
          }}, description: "At most 100 issues."}
    },
    mode: :write

  alias Helmsman.TaskSpecs
  alias HelmsmanMCP.Args

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id} = args, %{scope: scope}) do
    attrs = Args.take(args, [:version, :verdict, :summary, :issues])

    with {:ok, %{review: n} = result} <- TaskSpecs.submit_review(scope, id, attrs) do
      issues = for i <- 1..length(args["issues"] || [])//1, do: "R#{n}.#{i}"
      {:ok, Map.put(result, :issues, issues)}
    end
  end
end
