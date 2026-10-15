defmodule HelmsmanMCP.Tools.DiffSpec do
  @moduledoc "`diff_spec`: the line diff of two versions of a task's spec (decision 17)."

  use HelmsmanMCP.Tool,
    name: "diff_spec",
    description:
      "Compare two versions of a task's spec, file by file, as unified diffs (3 lines of " <>
        "context). Version 0 is the empty spec.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      from: {:required, :integer, description: "The older version (0: no files)."},
      to: {:integer, description: "The newer version (default the latest)."}
    },
    mode: :read

  alias Helmsman.TaskSpecs
  alias HelmsmanMCP.SpecPresent

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id, "from" => from} = args, %{scope: scope}) do
    with {:ok, to} <- to(scope, id, args["to"]),
         {:ok, diff} <- TaskSpecs.diff(scope, id, from, to),
         do: {:ok, SpecPresent.diff(diff)}
  end

  defp to(_scope, _id, to) when is_integer(to), do: {:ok, to}

  defp to(scope, id, nil) do
    case TaskSpecs.summary(scope, id) do
      {:ok, nil} -> {:error, {:spec, :not_found, id}}
      {:ok, spec} -> {:ok, spec.latest_version}
      error -> error
    end
  end
end
