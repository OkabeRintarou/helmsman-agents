defmodule HelmsmanMCP.Tools do
  @moduledoc "The registry of MCP tools."

  alias HelmsmanMCP.Tools.{
    AddFeedback,
    CancelRun,
    CreateProject,
    CreateTask,
    GetProject,
    GetTask,
    Identify,
    LinkTasks,
    ListActors,
    ListAgents,
    ListFeedback,
    ListMyTasks,
    ListProjects,
    ListRuns,
    ListTasks,
    RunAgent,
    TransitionTask,
    UnlinkTasks,
    UpdateFeedback,
    UpdateProject,
    UpdateTask,
    Whoami
  }

  @tools [
    Identify,
    Whoami,
    ListActors,
    ListProjects,
    GetProject,
    CreateProject,
    UpdateProject,
    ListTasks,
    GetTask,
    CreateTask,
    UpdateTask,
    ListMyTasks,
    TransitionTask,
    LinkTasks,
    UnlinkTasks,
    AddFeedback,
    UpdateFeedback,
    ListFeedback,
    ListAgents,
    RunAgent,
    ListRuns,
    CancelRun
  ]

  @doc "Every tool module."
  @spec all() :: [module()]
  def all, do: @tools

  @doc "Finds a tool module by name."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(@tools, &(&1.name() == name)) do
      nil -> :error
      module -> {:ok, module}
    end
  end
end
