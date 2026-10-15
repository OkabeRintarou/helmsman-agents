defmodule Helmsman.TaskSpecs.Spec do
  @moduledoc """
  A task's spec (`add-spec-workflow` decisions 1, 2): at most one per task.

  `status`, `change_id`, `latest_version`, `final_version` and the proposal
  columns are the only mutable state; each change appends an audit event
  in the same transaction and `Helmsman.TaskSpecs.State.replay/2` derives
  them from the events (decision 6). `request_seq`, `review_seq` and
  `event_seq` hand out the numbers of requests, reviews and events.
  """

  use Ecto.Schema

  alias Helmsman.Actors.Actor
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Workspace

  @type status :: :draft | :in_review | :pending_approval | :finalized | :abandoned
  @type t :: %__MODULE__{}

  @statuses [:draft, :in_review, :pending_approval, :finalized, :abandoned]

  schema "task_specs" do
    belongs_to :workspace, Workspace
    belongs_to :task, Task
    field :change_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :latest_version, :integer, default: 0
    field :final_version, :integer
    field :proposal_version, :integer
    field :proposal_summary, :string
    belongs_to :proposal_by, Actor
    belongs_to :proposal_run, Run
    field :proposed_at, :utc_datetime_usec
    field :request_seq, :integer, default: 0
    field :review_seq, :integer, default: 0
    field :event_seq, :integer, default: 0
    belongs_to :created_by, Actor
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The spec statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses
end
