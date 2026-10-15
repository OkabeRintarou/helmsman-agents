defmodule HelmsmanMCP.Tools.ListSpecReviews do
  @moduledoc "`list_spec_reviews`: the reviews, issues and requests of a task's spec."

  use HelmsmanMCP.Tool,
    name: "list_spec_reviews",
    description:
      "List the reviews of a task's spec (number, version, reviewer, verdict, summary) with " <>
        "their issues (R<review>.<n>, severity, location, body, suggestion, resolution and " <>
        "discussion), and the review requests (pending ones have status requested).",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      version: {:integer, description: "Only the reviews of this version."},
      unresolved_only:
        {:boolean, description: "Only the open or disputed issues and their reviews."}
    },
    mode: :read

  alias Helmsman.TaskSpecs
  alias HelmsmanMCP.SpecPresent

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id} = args, %{scope: scope}) do
    opts = [version: args["version"], unresolved_only: args["unresolved_only"] == true]

    with {:ok, reviews} <- TaskSpecs.reviews(scope, id, opts),
         do: {:ok, SpecPresent.reviews(reviews)}
  end
end
