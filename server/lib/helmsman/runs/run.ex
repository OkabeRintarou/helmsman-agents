defmodule Helmsman.Runs.Run do
  @moduledoc """
  A run (designs/13 §1): one execution of a managed agent, on the runtime
  bound to it when the run was created, usually for a task.

  This change adds the columns dispatch needs; `add-run-lifecycle` adds
  those of claiming and execution. `triggers` lists why the run exists,
  each entry with its own authorization source and causal chain
  (`%{"kind", "by_actor_id", "initiator_user_id", "causal_agent_ids",
  "instructions", "feedback_id", "at"}`); `root_initiator_user_id` is that
  of the earliest trigger.
  """

  use Ecto.Schema

  alias Helmsman.Accounts.User
  alias Helmsman.Actors.Actor
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Workspace

  @type status ::
          :deferred
          | :queued
          | :claimed
          | :running
          | :cancelling
          | :succeeded
          | :failed
          | :cancelled
  @type t :: %__MODULE__{}

  @statuses [:deferred, :queued, :claimed, :running, :cancelling, :succeeded, :failed, :cancelled]
  @pending [:deferred, :queued]
  @active [:claimed, :running, :cancelling]
  @capabilities ["read", "write_task", "create_tasks", "delegate"]
  @failure_reasons [
    :runtime_offline,
    :daemon_restart,
    :lease_expired,
    :timeout,
    :stalled,
    :provider_network,
    :provider_rate_limit,
    :provider_auth,
    :provider_quota,
    :cli_missing,
    :cli_version,
    :workspace_prepare,
    :push_conflict,
    :push_failed,
    :context_overflow,
    :obsolete,
    :unauthorized,
    :cli_error,
    :unknown
  ]

  schema "runs" do
    belongs_to :workspace, Workspace
    belongs_to :agent, Actor
    belongs_to :runtime, Runtime
    belongs_to :task, Task
    field :lane, Ecto.Enum, values: [:work, :reply]
    field :status, Ecto.Enum, values: @statuses
    field :triggers, {:array, :map}, default: []
    belongs_to :root_initiator_user, User
    field :causal_agent_ids, {:array, :integer}, default: []
    field :capabilities, {:array, :string}, default: []
    field :priority, :integer
    field :failure_reason, Ecto.Enum, values: @failure_reasons

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every status."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Statuses of a run waiting to be claimed (it can take more triggers)."
  @spec pending_statuses() :: [status()]
  def pending_statuses, do: @pending

  @doc "Statuses of a claimed run that has not ended (its token is valid)."
  @spec active_statuses() :: [status()]
  def active_statuses, do: @active

  @doc "Every capability a run can have."
  @spec capabilities() :: [String.t()]
  def capabilities, do: @capabilities
end
