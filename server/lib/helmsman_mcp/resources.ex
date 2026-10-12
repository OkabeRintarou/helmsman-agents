defmodule HelmsmanMCP.Resources do
  @moduledoc """
  The MCP resources (designs/08 §4), independent of the MCP library:

    * `helmsman://workflow` - `docs/AGENT-WORKFLOW.en.md`, read at compile
      time (a release does not need `docs/`);
    * `helmsman://projects` - the workspace's active projects, as
      `list_projects` returns them;
    * `helmsman://tasks/{id}` - a task as Markdown (`HelmsmanMCP.TaskMarkdown`).
  """

  alias Helmsman.{Projects, Tasks}
  alias HelmsmanMCP.{Context, Present, TaskMarkdown}

  @workflow_path Path.expand("../../../docs/AGENT-WORKFLOW.en.md", __DIR__)
  @external_resource @workflow_path
  @workflow File.read!(@workflow_path)

  @tasks_prefix "helmsman://tasks/"

  @type resource :: %{
          required(:name) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t(),
          required(:mime_type) => String.t(),
          optional(:uri) => String.t(),
          optional(:uri_template) => String.t()
        }

  @doc "The collaboration rules, `docs/AGENT-WORKFLOW.en.md`."
  @spec workflow() :: String.t()
  def workflow, do: @workflow

  @doc "The resources with a fixed URI."
  @spec list() :: [resource()]
  def list do
    [
      %{
        uri: "helmsman://workflow",
        name: "workflow",
        title: "Helmsman agent workflow",
        description:
          "The collaboration rules: roles, statuses and transitions, what to do at each " <>
            "step, feedback.",
        mime_type: "text/markdown"
      },
      %{
        uri: "helmsman://projects",
        name: "projects",
        title: "Projects",
        description: "The active projects of this workspace (JSON, as list_projects returns).",
        mime_type: "application/json"
      }
    ]
  end

  @doc "The resource templates."
  @spec templates() :: [resource()]
  def templates do
    [
      %{
        uri_template: @tasks_prefix <> "{id}",
        name: "task",
        title: "Task",
        description:
          "A task as Markdown: fields, description, history and active feedback " <>
            "(e.g. helmsman://tasks/BOS-12).",
        mime_type: "text/markdown"
      }
    ]
  end

  @doc """
  The arguments error texts get for `uri` (`HelmsmanMCP.ErrorText`): the
  task ID of a task URI.
  """
  @spec args(String.t()) :: map()
  def args(@tasks_prefix <> id), do: %{"uri" => @tasks_prefix <> id, "task_id" => id}
  def args(uri), do: %{"uri" => uri}

  @doc """
  Reads the resource `uri` as `ctx.scope`. `{:error, :not_found}` for an
  unknown URI or task.
  """
  @spec read(String.t(), Context.t()) :: {:ok, String.t()} | {:error, term()}
  def read("helmsman://workflow", _ctx), do: {:ok, @workflow}

  def read("helmsman://projects", %Context{scope: scope}) do
    with {:ok, projects} <- Projects.list(scope) do
      {:ok, Jason.encode!(Enum.map(projects, &Present.project/1))}
    end
  end

  def read(@tasks_prefix <> id, %Context{scope: scope}) do
    with {:ok, task} <- Tasks.get(scope, id), do: {:ok, TaskMarkdown.render(Tasks.detail(task))}
  end

  def read(_uri, _ctx), do: {:error, :not_found}
end
