defmodule HelmsmanMCP.Tools do
  @moduledoc "The registry of MCP tools."

  alias HelmsmanMCP.Tools.{
    AddFeedback,
    CancelRun,
    CreateProject,
    CreateTask,
    Delegate,
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
    ProposeSquad,
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
    Delegate,
    ListRuns,
    CancelRun,
    GetDesign,
    ProposeAgent,
    WithdrawAgent,
    ProposeSquad
  ]

  # The draft tools, listed only for design runs (`add-agent-conversation`
  # decision 7).
  @design_tools [GetDesign, ProposeAgent, WithdrawAgent, ProposeSquad]

  @doc "Every tool module."
  @spec all() :: [module()]
  def all, do: @tools

  # Listed only for runs as a squad leader (`add-squads` decision 8).
  @delegate_tools [Delegate]

  @doc "The names of the tools listed only for design runs."
  @spec design_tool_names() :: [String.t()]
  def design_tool_names, do: Enum.map(@design_tools, & &1.name())

  @doc """
  The run capability each restricted tool needs to be listed: the draft
  tools `design`, `delegate` its own.
  """
  @spec required_capabilities() :: %{String.t() => String.t()}
  def required_capabilities do
    Map.new(@design_tools, &{&1.name(), "design"})
    |> Map.merge(Map.new(@delegate_tools, &{&1.name(), "delegate"}))
  end

  @doc "Finds a tool module by name."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(@tools, &(&1.name() == name)) do
      nil -> :error
      module -> {:ok, module}
    end
  end
end
