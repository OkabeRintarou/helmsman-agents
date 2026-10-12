defmodule Helmsman.Runs.TaskGrant do
  @moduledoc """
  An authorization record (designs/13 §2.2): a task was assigned to a
  managed agent by someone allowed to trigger it (`assign`), or a managed
  agent created it in a run (`requested`, `add-continuation-triggers`
  decision 5). Continuation triggers inherit `root_initiator_user_id` and
  `causal_agent_ids` from here. A change of assignee removes the task's
  `assign` grants only.
  """

  use Ecto.Schema

  alias Helmsman.Accounts.User
  alias Helmsman.Actors.Actor
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Workspace

  @type t :: %__MODULE__{}

  schema "task_grants" do
    belongs_to :workspace, Workspace
    belongs_to :task, Task
    belongs_to :agent, Actor
    field :kind, Ecto.Enum, values: [:assign, :requested]
    belongs_to :root_initiator_user, User
    field :causal_agent_ids, {:array, :integer}, default: []
    belongs_to :granted_by, Actor
    field :inserted_at, :utc_datetime_usec
  end
end
