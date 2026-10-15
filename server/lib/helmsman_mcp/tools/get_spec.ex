defmodule HelmsmanMCP.Tools.GetSpec do
  @moduledoc "`get_spec`: a task's spec, its versions and one version's files (decision 20)."

  use HelmsmanMCP.Tool,
    name: "get_spec",
    description:
      "Show a task's spec (OpenSpec change: proposal.md, design.md, tasks.md, " <>
        "specs/<capability>/spec.md): status, versions, and one version (default the latest) " <>
        "with its validation result and files. Above 256 KB without files, only the file " <>
        "list comes back: read the files in batches with files.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      version: {:integer, description: "The version to show (default the latest)."},
      files: {:list, :string, description: "Only these paths' content (e.g. [\"proposal.md\"])."}
    },
    mode: :read

  alias Helmsman.TaskSpecs
  alias HelmsmanMCP.SpecPresent

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id} = args, %{scope: scope}) do
    with {:ok, result} <-
           TaskSpecs.get(scope, id, version: args["version"], files: args["files"]),
         do: {:ok, SpecPresent.get(result, is_nil(args["files"]))}
  end
end
