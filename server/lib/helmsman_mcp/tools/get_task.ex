defmodule HelmsmanMCP.Tools.GetTask do
  @moduledoc "`get_task`: a task's detail."

  use HelmsmanMCP.Tool,
    name: "get_task",
    description:
      "Show a task: fields, description, full history (with evidence) and every feedback " <>
        "record, revised ones included. lock_version is its current version.",
    schema: %{task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."}},
    mode: :read

  alias Helmsman.Tasks
  alias HelmsmanMCP.Present

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id}, %{scope: scope}) do
    with {:ok, task} <- Tasks.get(scope, id), do: {:ok, Present.detail(Tasks.detail(task))}
  end
end
