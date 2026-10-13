defmodule HelmsmanMCP.Tools.ListTasks do
  @moduledoc "`list_tasks`: the tasks of a project."

  use HelmsmanMCP.Tool,
    name: "list_tasks",
    description:
      "List the tasks of a project, most recently updated first. Status names are " <>
        "case-insensitive (IN_PROGRESS, in progress and in-progress are the same).",
    schema: %{
      project_key: {:required, :string, description: "Project key (e.g. BOS)."},
      status:
        {:meta, {:oneof, [:string, {:list, :string}]},
         [
           description:
             "A status or a list of statuses: NEW, IN_PROGRESS, DONE, VERIFIED, REJECTED, " <>
               "CANCELLED."
         ]},
      label: {:string, description: "Only tasks with this label."},
      assignee: {:string, description: "Only tasks of this identity; \"\" for unassigned."},
      kind: {:string, description: "Only tasks of this kind: task or epic."},
      epic:
        {:string,
         description: "Only the steps of this epic (e.g. BOS-1); \"\" for tasks in no epic."},
      query:
        {:string,
         description:
           "Only tasks whose ID, labels, title, description or feedback match this text."},
      limit: {:integer, description: "At most this many tasks (default 50, at most 200)."},
      offset: {:integer, description: "Skip this many tasks (default 0)."}
    },
    mode: :read

  alias Helmsman.Tasks
  alias HelmsmanMCP.{Args, Present}

  @impl HelmsmanMCP.Tool
  def call(%{"project_key" => key} = args, %{scope: scope}) do
    with {:ok, statuses} <- Args.statuses(args["status"]) do
      opts =
        args
        |> Args.take([:label, :assignee, :kind, :epic, :limit, :offset])
        |> Map.put(:status, statuses)
        |> Map.put(:q, args["query"])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      with {:ok, tasks} <- Tasks.list(scope, key, opts) do
        {:ok, Enum.map(tasks, &(&1 |> Tasks.summary() |> Present.summary()))}
      end
    end
  end
end
