defmodule HelmsmanMCP.Tools.SubmitSpecVersion do
  @moduledoc "`submit_spec_version`: a new version of a task's spec (decision 3)."

  use HelmsmanMCP.Tool,
    name: "submit_spec_version",
    description:
      "Submit a new version of a task's spec (an OpenSpec change), creating the spec when " <>
        "the task has none (base_version 0). Give only the changed or new files and the " <>
        "paths to remove; the others are kept from base_version. Paths: proposal.md, " <>
        "design.md, tasks.md, specs/<capability>/spec.md. A version that fails validation " <>
        "is kept as a draft: fix it before the spec can be finalized.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      base_version:
        {:required, :integer, description: "The latest version you read (0 when there is none)."},
      files:
        {:list,
         {:object,
          %{
            path: {:required, :string, description: "e.g. specs/settings/spec.md"},
            content: {:required, :string, description: "The whole file (Markdown)."}
          }}, description: "Changed and new files."},
      remove: {:list, :string, description: "Paths to delete."},
      note: {:string, description: "What changed (at most 4 KB)."},
      change_id:
        {:string,
         description: "The change's ID while the spec has no version (default the task ID)."},
      dry_run: {:boolean, description: "Only validate; nothing is saved."}
    },
    mode: :write

  alias Helmsman.TaskSpecs
  alias HelmsmanMCP.Args

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id} = args, %{scope: scope}) do
    attrs = Args.take(args, [:base_version, :files, :remove, :note, :change_id, :dry_run])

    with {:ok, result} <- TaskSpecs.submit_version(scope, id, attrs),
         do: {:ok, with_hint(result)}
  end

  defp with_hint(%{validation: %{valid: false}} = result) do
    Map.put(
      result,
      :hint,
      "This version does not pass validation and stays a draft: fix the errors and submit " <>
        "a new version before the spec can be finalized."
    )
  end

  defp with_hint(result), do: result
end
