defmodule HelmsmanMCP.Tools.UpdateTask do
  @moduledoc "`update_task`: edits a task's fields, never its status."

  use HelmsmanMCP.Tool,
    name: "update_task",
    description:
      "Edit a task's title, description, priority, labels or assignee. The status cannot " <>
        "be changed here: use transition_task. With lock_version, the edit fails if " <>
        "someone changed the task since you read it; without it, the latest version is edited.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      title: {:string, description: "New title."},
      description: {:string, description: "New Markdown description."},
      priority: {:string, description: "low, medium or high."},
      labels: {:list, :string, description: "New labels (replace the old ones)."},
      assignee: {:string, description: "Identity name; \"\" to unassign."},
      lock_version: {:integer, description: "The lock_version you read (get_task)."}
    },
    mode: :write

  alias Helmsman.Tasks
  alias HelmsmanMCP.{Args, Present}

  @fields [:title, :description, :priority, :labels, :assignee]

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id} = args, %{scope: scope}) do
    with {:ok, task} <- Tasks.update(scope, id, Args.take(args, @fields), args["lock_version"]) do
      {:ok, Present.detail(Tasks.detail(task))}
    end
  end
end
