defmodule HelmsmanMCP.Tools do
  @moduledoc "The registry of MCP tools."

  alias HelmsmanMCP.Tools.{
    AddFeedback,
    CancelRun,
    CreateProject,
    CreateTask,
    GetDesign,
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
    ProposeAgent,
    RunAgent,
    SearchTasks,
    TransitionTask,
    UnlinkTasks,
    UpdateFeedback,
    UpdateProject,
    UpdateTask,
    Whoami,
    WithdrawAgent
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
    SearchTasks,
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
    CancelRun,
    GetDesign,
    ProposeAgent,
    WithdrawAgent
  ]

  # The draft tools, listed only for design runs (`add-agent-conversation`
  # decision 7).
  @design_tools [GetDesign, ProposeAgent, WithdrawAgent]

  @doc "Every tool module."
  @spec all() :: [module()]
  def all, do: @tools

  @doc "The names of the tools listed only for design runs."
  @spec design_tool_names() :: [String.t()]
  def design_tool_names, do: Enum.map(@design_tools, & &1.name())

  @doc "Finds a tool module by name."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(@tools, &(&1.name() == name)) do
      nil -> :error
      module -> {:ok, module}
    end
  end
end
