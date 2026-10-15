defmodule HelmsmanMCP.Tools.UnlinkTasks do
  @moduledoc "`unlink_tasks`: removes a link between two tasks (`Helmsman.Links.remove/4`)."

  use HelmsmanMCP.Tool,
    name: "unlink_tasks",
    description:
      "Remove the link from -> to of type depends_on (from waits for to) or replaces (from " <>
        "took over to). No status changes: a replaced task stays CANCELLED. Removing a link " <>
        "that does not exist succeeds. Returns from. A run orchestrating its squad's work may " <>
        "also remove depends_on links between the tasks it orchestrates.",
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
    with {:ok, detail} <- Links.remove(scope, from, to, type), do: {:ok, Present.detail(detail)}
  end
end
