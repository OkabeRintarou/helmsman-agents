defmodule HelmsmanMCP.Test.RejectingTool do
  @moduledoc """
  A write tool compiled for tests only: adds a feedback to `task_id`, then
  refuses with `HelmsmanMCP.Rejected`, to show that the write commits and
  the call still answers with an error.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  use HelmsmanMCP.Tool,
    name: "test_rejecting",
    description: "Test only.",
    schema: %{task_id: {:required, :string, description: "Task ID."}},
    mode: :write

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id}, %{scope: scope}) do
    with {:ok, _entry} <- Helmsman.Feedback.add(scope, id, %{content: "before the refusal"}) do
      {:ok, %HelmsmanMCP.Rejected{reason: {:not_dispatched, :rate_limited}}}
    end
  end
end
