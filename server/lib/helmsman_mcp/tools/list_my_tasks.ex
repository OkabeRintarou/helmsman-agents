defmodule HelmsmanMCP.Tools.ListMyTasks do
  @moduledoc "`list_my_tasks`: the tasks assigned to the current identity."

  use HelmsmanMCP.Tool,
    name: "list_my_tasks",
    description:
      "List the tasks assigned to your current identity in every project, most recently " <>
        "updated first (at most 200). Default statuses: NEW and IN_PROGRESS. Needs an " <>
        "identity: call identify first.",
    schema: %{
      status:
        {:meta, {:oneof, [:string, {:list, :string}]},
         [description: "A status or a list of statuses (case-insensitive)."]}
    },
    mode: :read

  alias Helmsman.Tasks
  alias HelmsmanMCP.{Args, Present}

  @impl HelmsmanMCP.Tool
  def call(args, %{scope: scope}) do
    with {:ok, statuses} <- Args.statuses(args["status"]),
         {:ok, summaries} <- Tasks.list_assigned(scope, status: statuses) do
      {:ok, Enum.map(summaries, &Present.summary/1)}
    end
  end
end
