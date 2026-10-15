defmodule HelmsmanMCP.Tools do
  @moduledoc "The registry of MCP tools."

  alias HelmsmanMCP.Tools.{
    AddFeedback,
    CancelRun,
    CancelSpecReview,
    CreateProject,
    CreateTask,
    Delegate,
    DeleteFilter,
    DiffSpec,
    FinalizeSpec,
    GetDesign,
    GetProject,
    GetSpec,
    GetTask,
    Identify,
    LinkTasks,
    ListActors,
    ListAgents,
    ListFeedback,
    ListFilters,
    ListMyTasks,
    ListProjects,
    ListRuns,
    ListSpecReviews,
    ListTasks,
    ProposeAgent,
    ProposeSquad,
    QueryTasks,
    ReplySpecIssue,
    RequestSpecReview,
    RuleSpecIssue,
    RunAgent,
    SaveFilter,
    SearchTasks,
    SubmitSpecReview,
    SubmitSpecVersion,
    TransitionTask,
    UnlinkTasks,
    UpdateFeedback,
    UpdateProject,
    UpdateSpec,
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
    QueryTasks,
    ListFilters,
    SaveFilter,
    DeleteFilter,
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
    GetSpec,
    DiffSpec,
    ListSpecReviews,
    SubmitSpecVersion,
    SubmitSpecReview,
    ReplySpecIssue,
    RuleSpecIssue,
    FinalizeSpec,
    UpdateSpec,
    CancelSpecReview,
    RequestSpecReview,
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

  # `add-spec-workflow` decision 20: a run lists the spec writes only with
  # `write_task`, and never `request_spec_review` (runs use `delegate`).
  @spec_write_tools [
    SubmitSpecVersion,
    SubmitSpecReview,
    ReplySpecIssue,
    RuleSpecIssue,
    FinalizeSpec,
    UpdateSpec,
    CancelSpecReview
  ]
  @session_only_tools [RequestSpecReview]

  @doc """
  The tools a run lists only with a capability (`%{name => capability}`),
  on top of `required_capabilities/0`, which applies to every caller.
  """
  @spec run_capabilities() :: %{String.t() => String.t()}
  def run_capabilities, do: Map.new(@spec_write_tools, &{&1.name(), "write_task"})

  @doc "The tools never listed for a run token."
  @spec session_only_names() :: [String.t()]
  def session_only_names, do: Enum.map(@session_only_tools, & &1.name())

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
