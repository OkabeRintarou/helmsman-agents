defmodule HelmsmanMCP.Tools.GetTask do
  @moduledoc "`get_task`: a task's detail."

  use HelmsmanMCP.Tool,
    name: "get_task",
    description:
      "Show a task: fields, description, full history (with evidence) and every feedback " <>
        "record, revised ones included. lock_version is its current version. spec summarizes " <>
        "the task's spec (null without one; read it with get_spec). An epic's steps " <>
        "(children) say what each waits for (waiting_for, blocked_by) and, in a run, " <>
        "whether you may orchestrate it (orchestrable).",
    schema: %{task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."}},
    mode: :read

  alias Helmsman.Tasks
  alias Helmsman.Tasks.StepViews
  alias HelmsmanMCP.{Present, TaskMarkdown}

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id}, %{scope: scope}) do
    with {:ok, task} <- Tasks.get(scope, id) do
      {:ok,
       task
       |> Tasks.detail()
       |> Present.detail()
       |> Map.put(:spec, TaskMarkdown.spec(scope, task))
       |> with_steps(scope, task)}
    end
  end

  # An epic's steps say what they wait for (`improve-squad-leader-orchestration`
  # decision 13).
  defp with_steps(%{children: [_ | _] = children} = view, scope, task) do
    steps = StepViews.for_epic(scope, task)
    %{view | children: Enum.map(children, &Map.merge(&1, Map.get(steps, &1.id, %{})))}
  end

  defp with_steps(view, _scope, _task), do: view
end
