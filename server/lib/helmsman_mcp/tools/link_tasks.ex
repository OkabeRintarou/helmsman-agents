defmodule HelmsmanMCP.Tools.LinkTasks do
  @moduledoc "`link_tasks`: links two tasks (`Helmsman.Links.add/4`)."

  use HelmsmanMCP.Tool,
    name: "link_tasks",
    description:
      "Link two tasks of the workspace (any projects). type depends_on: from waits for to " <>
        "(from is blocked and cannot start until to is finished). type replaces: from takes " <>
        "over to (to is cancelled if it is still NEW or IN_PROGRESS, and cannot be reopened " <>
        "while the link exists). Adding an existing link changes nothing. Returns from. A run " <>
        "may link its own task; a run orchestrating its squad's work may also add depends_on " <>
        "links between the tasks it orchestrates.",
    schema: %{
      from: {:required, :string, description: "Task ID of the linking task (e.g. WEB-2)."},
      to: {:required, :string, description: "Task ID of the linked task (e.g. BOS-1)."},
      type: {:required, :string, description: "depends_on or replaces."}
    },
    mode: :write

  alias Helmsman.Links
  alias HelmsmanMCP.Present

  @impl HelmsmanMCP.Tool
  def call(%{"from" => from, "to" => to, "type" => type}, %{scope: scope}) do
    with {:ok, detail} <- Links.add(scope, from, to, type), do: {:ok, Present.detail(detail)}
  end
end
