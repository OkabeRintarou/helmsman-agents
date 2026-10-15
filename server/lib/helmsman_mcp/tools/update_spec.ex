defmodule HelmsmanMCP.Tools.UpdateSpec do
  @moduledoc "`update_spec`: creates an empty spec, renames it, abandons or reopens it."

  use HelmsmanMCP.Tool,
    name: "update_spec",
    description:
      "Create an empty spec for a task (when it has none) or change its change_id; with " <>
        "status abandoned (give up) or draft (reopen a finalized or abandoned spec) and a " <>
        "reason. Returns the spec.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      change_id:
        {:string, description: "2-64 characters of a-z, 0-9 and - (e.g. add-settings-page)."},
      status: {:string, description: "abandoned or draft."},
      reason: {:string, description: "Why (required with status, at most 4 KB)."}
    },
    mode: :write

  alias Helmsman.TaskSpecs
  alias HelmsmanMCP.{Args, SpecPresent}

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id} = args, %{scope: scope}) do
    with {:ok, spec} <-
           TaskSpecs.update(scope, id, Args.take(args, [:change_id, :status, :reason])),
         do: {:ok, SpecPresent.summary(spec)}
  end
end
