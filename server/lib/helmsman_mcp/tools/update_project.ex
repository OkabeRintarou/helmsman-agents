defmodule HelmsmanMCP.Tools.UpdateProject do
  @moduledoc """
  `update_project`: renames, describes, archives or restores a project
  (admins and above).

  The fields change first, then the archive state. The pipeline runs the
  call in one outer transaction: both steps commit together, and a failure
  of either rolls both back, with no notification.
  """

  use HelmsmanMCP.Tool,
    name: "update_project",
    description:
      "Change a project's name or description, archive it (archived: true; it takes no " <>
        "new tasks) or restore it (archived: false). Admins and owners only. The key " <>
        "never changes.",
    schema: %{
      key: {:required, :string, description: "Project key (case-insensitive)."},
      name: {:string, description: "New name, 1-80 characters."},
      description: {:string, description: "New Markdown description."},
      archived: {:boolean, description: "true archives the project, false restores it."}
    },
    mode: :write

  alias Helmsman.Projects
  alias HelmsmanMCP.{Args, Present}

  @impl HelmsmanMCP.Tool
  def call(%{"key" => key} = args, %{scope: scope}) do
    fields = Args.take(args, [:name, :description])

    with {:ok, project} <- update_fields(scope, key, fields, args["archived"]),
         {:ok, project} <- set_archived(scope, key, args["archived"], project) do
      {:ok, Present.project(project)}
    end
  end

  # Without fields, an archive change goes alone; with neither, the update
  # still authorizes the call and returns the project.
  defp update_fields(_scope, _key, fields, archived)
       when fields == %{} and is_boolean(archived),
       do: {:ok, nil}

  defp update_fields(scope, key, fields, _archived), do: Projects.update(scope, key, fields)

  defp set_archived(_scope, _key, archived, project) when not is_boolean(archived),
    do: {:ok, project}

  defp set_archived(scope, key, archived, _project) do
    with :ok <- test_hook(:set_archived) do
      if archived, do: Projects.archive(scope, key), else: Projects.unarchive(scope, key)
    end
  end

  # Fault injection for the atomicity tests: compiled in the test
  # environment only.
  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _ -> :ok
      end
    end
  else
    defp test_hook(_point), do: :ok
  end
end
