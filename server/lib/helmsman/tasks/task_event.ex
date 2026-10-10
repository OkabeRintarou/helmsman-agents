defmodule Helmsman.Tasks.TaskEvent do
  @moduledoc """
  One entry of a task's history: a status change (or the creation, with no
  `from_status`), who made it and the evidence attached to it (`comment`,
  `commits`, `tests`). `auto` marks transitions the system made on its own.
  Rows are only ever inserted.

  `tests`, when present, is `%{"command" => String.t(), "passed" =>
  boolean(), "summary" => String.t()}` (see `Helmsman.Tasks.Evidence`).
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
    field :commits, {:array, :string}, default: []
    field :tests, :map
    field :auto, :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
