defmodule HelmsmanMCP.Tools.ListFeedback do
  @moduledoc "`list_feedback`: every feedback record of a task."

  use HelmsmanMCP.Tool,
    name: "list_feedback",
    description:
      "List every feedback record of a task by number, superseded ones included " <>
        "(status and superseded_by show the current version).",
    schema: %{task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."}},
    mode: :read

  alias Helmsman.Feedback
  alias Helmsman.Tasks.Ident
  alias HelmsmanMCP.Present

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id}, %{scope: scope}) do
    with {:ok, entries} <- Feedback.list(scope, id),
         {:ok, ident, _key, _seq} <- Ident.parse(id) do
      {:ok,
       %{
         task_id: ident,
         feedback: Enum.map(entries, &(&1 |> Feedback.view() |> Present.feedback()))
       }}
    end
  end
end
