defmodule Helmsman.Tasks.TaskEvent do
  @moduledoc """
  One entry of a task's history: a status change (or the creation, with no
  `from_status`) and who made it. Rows are only ever inserted.
  """

  use Ecto.Schema

  alias Helmsman.Actors.Actor
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Workspace

  @type t :: %__MODULE__{}

  schema "task_events" do
    belongs_to :workspace, Workspace
    belongs_to :task, Task
    field :from_status, Ecto.Enum, values: Task.statuses()
    field :to_status, Ecto.Enum, values: Task.statuses()
    belongs_to :actor, Actor
    field :comment, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
