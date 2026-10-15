defmodule HelmsmanMCP.Tools.CancelSpecReview do
  @moduledoc "`cancel_spec_review`: withdraws a pending review request."

  use HelmsmanMCP.Tool,
    name: "cancel_spec_review",
    description:
      "Cancel the pending review request of a reviewer on the latest version of a task's " <>
        "spec (as its requester, the coordinator or a person).",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      reviewer: {:required, :string, description: "The reviewer (e.g. keel/review)."}
    },
    mode: :write

  alias Helmsman.TaskSpecs
  alias HelmsmanMCP.SpecPresent

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id, "reviewer" => reviewer}, %{scope: scope}) do
    with {:ok, result} <- TaskSpecs.cancel_request(scope, id, %{reviewer: reviewer}),
         do: {:ok, %{result | spec: SpecPresent.summary(result.spec)}}
  end
end
