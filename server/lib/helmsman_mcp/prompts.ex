defmodule HelmsmanMCP.Prompts do
  @moduledoc """
  The MCP prompts (designs/08 §4), independent of the MCP library:
  `work_on_task(task_id)` is the task, the collaboration rules and the
  instructions to claim, work and finish it, in one user message.
  """

  alias Helmsman.Tasks
  alias HelmsmanMCP.{Context, Resources, TaskMarkdown}

  @type prompt :: %{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          arguments: map()
        }

  @doc "Every prompt."
  @spec list() :: [prompt()]
  def list do
    [
      %{
        name: "work_on_task",
        title: "Work on a task",
        description:
          "Start on a Helmsman task: its full text, the workflow rules and the steps to " <>
            "claim, work and finish it.",
        arguments: %{task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."}}
      }
    ]
  end

  @doc """
  The text of the prompt `name` with `ctx.args`, as `ctx.scope`.
  `{:error, :not_found}` for an unknown prompt or task.
  """
  @spec get(String.t(), Context.t()) :: {:ok, String.t()} | {:error, term()}
  def get("work_on_task", %Context{args: %{"task_id" => id}, scope: scope}) when is_binary(id) do
    with {:ok, task} <- Tasks.get(scope, id) do
      {:ok,
       Enum.join(
         [
           TaskMarkdown.render(Tasks.detail(task)),
           Resources.workflow(),
           instructions(task.ident)
         ],
         "\n---\n\n"
       )}
    end
  end

  def get(_name, _ctx), do: {:error, :not_found}

  @doc "The instructions of `work_on_task` for the task `id`."
  @spec instructions(String.t()) :: String.t()
  def instructions(id) do
    "If the task has an unanswered question, do not start; wait for the answer. " <>
      "Before changing anything, claim it: transition_task(#{id}, \"IN_PROGRESS\"). " <>
      "When finished: add_feedback(kind: \"comment\") describing what changed, then " <>
      "transition_task(#{id}, \"DONE\", commits: [...], tests: {...}).\n"
  end
end
