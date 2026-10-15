defmodule HelmsmanMCP.Tools.CreateTask do
  @moduledoc "`create_task`: a new task, created by the writing identity."

  use HelmsmanMCP.Tool,
    name: "create_task",
    description:
      "Create a task in a project. It starts as NEW, created by your identity. Returns " <>
        "the task with its ID. kind: \"epic\" creates an epic (a goal whose steps are " <>
        "tasks); epic puts the new task under an epic as one of its steps; depends_on makes it " <>
        "wait for other tasks.",
    schema: %{
      project_key: {:required, :string, description: "Project key (e.g. BOS)."},
      title: {:required, :string, description: "Title, 1-200 characters."},
      description: {:string, description: "Markdown description."},
      priority: {:string, description: "low, medium (default) or high."},
      labels: {:list, :string, description: "Labels (lower-cased), at most 20."},
      start:
        {:boolean,
         description:
           "With an assignee that is a managed agent: false records the assignment " <>
             "without starting the agent (default true)."},
      assignee: {:string, description: "Identity name to assign the task to."},
      kind:
        {:string,
         description:
           "task (default) or epic. Cannot be changed later; an epic cannot belong to " <>
             "another epic."},
      epic:
        {:string,
         description:
           "ID of an epic (any project of the workspace, e.g. BOS-1) the task is a step of; " <>
             "\"\" for none."},
      depends_on:
        {:list, :string,
         description:
           "IDs of tasks (any project of the workspace) the new task waits for. With an " <>
             "assignee that is a managed agent, its run is deferred until they are done and " <>
             "starts by itself then; use it to order subtasks instead of start=false."}
    },
    mode: :write

  alias Helmsman.Tasks
  alias HelmsmanMCP.{Args, Present}

  @fields [
    :title,
    :description,
    :priority,
    :labels,
    :assignee,
    :start,
    :kind,
    :epic,
    :depends_on
  ]

  @impl HelmsmanMCP.Tool
  def call(%{"project_key" => key} = args, %{scope: scope}) do
    with {:ok, task} <- Tasks.create(scope, key, Args.take(args, @fields)) do
      {:ok, task |> Tasks.detail() |> Present.detail() |> Present.put_dispatch(task.dispatch)}
    end
  end
end
