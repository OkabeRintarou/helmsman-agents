defmodule HelmsmanMCP.Tools.CreateTask do
  @moduledoc "`create_task`: a new task, created by the writing identity."

  use HelmsmanMCP.Tool,
    name: "create_task",
    description:
      "Create a task in a project. It starts as NEW, created by your identity. Returns " <>
        "the task with its ID.",
    schema: %{
      project_key: {:required, :string, description: "Project key (e.g. BOS)."},
      title: {:required, :string, description: "Title, 1-200 characters."},
      description: {:string, description: "Markdown description."},
      priority: {:string, description: "low, medium (default) or high."},
      labels: {:list, :string, description: "Labels (lower-cased), at most 20."},
      assignee: {:string, description: "Identity name to assign the task to."}
    },
    mode: :write

  alias Helmsman.Tasks
  alias HelmsmanMCP.{Args, Present}

  @fields [:title, :description, :priority, :labels, :assignee]

  @impl HelmsmanMCP.Tool
  def call(%{"project_key" => key} = args, %{scope: scope}) do
    with {:ok, task} <- Tasks.create(scope, key, Args.take(args, @fields)) do
      {:ok, Present.detail(Tasks.detail(task))}
    end
  end
end
