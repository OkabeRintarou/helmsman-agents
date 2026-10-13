defmodule HelmsmanWeb.API.FeedbackController do
  @moduledoc """
  `/tasks/:id/feedback`: the MCP feedback tools over REST, and one record
  by its number (`GET /tasks/:id/feedback/:seq`, `add-rest-api` decision
  7). A record's ID is `KEY-N#seq`.
  """

  use HelmsmanWeb.API.Controller

  alias Helmsman.Feedback
  alias HelmsmanMCP.Present
  alias HelmsmanMCP.Tools.{AddFeedback, ListFeedback, UpdateFeedback}
  alias HelmsmanWeb.API.Params
  alias OpenApiSpex.Schema

  tool_action(:index, ListFeedback,
    path: [task_id: "id"],
    response: Schemas.FeedbackList,
    tag: "feedback"
  )

  tool_action(:create, AddFeedback,
    path: [task_id: "id"],
    status: 201,
    response: Schemas.Feedback,
    tag: "feedback"
  )

  tool_action(:update, UpdateFeedback,
    path: [feedback_id: {:feedback_id, "id", "seq"}],
    response: Schemas.Feedback,
    tag: "feedback"
  )

  def show(conn, %{"id" => ident, "seq" => seq}) do
    ToolAction.guarded(conn, "get_feedback", fn ->
      with {:ok, seq} <- ToolAction.positive_id(seq),
           {:ok, requested} <- Params.requested_actor(conn, nil),
           {:ok, scope, _source} <- ToolAction.reader_scope(conn.assigns.current_scope, requested),
           {:ok, entry} <- Feedback.get(scope, "#{ident}##{seq}") do
        ToolAction.data(conn, 200, Present.feedback(Feedback.view(entry)))
      end
    end)
  end

  @doc false
  def operation(:show) do
    Operations.manual(
      id: "get_feedback",
      summary: "get_feedback",
      description: "One feedback record of a task (BOS-12#3 is /tasks/BOS-12/feedback/3).",
      tag: "feedback",
      params: [
        {:id, :path, %Schema{type: :string}, "Task ID (e.g. BOS-12)."},
        {:seq, :path, %Schema{type: :integer}, "Feedback number in the task."}
      ],
      response: Schemas.Feedback
    )
  end
end
