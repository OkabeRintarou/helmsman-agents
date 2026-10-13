defmodule Helmsman.LocalRepositories.TaskLocalBranch do
  @moduledoc """
  The task branch of a task in its project's local repository
  (`add-local-repositories` decision 9): the latest delivered commit
  (`head_sha`) and whether it is merged into the base branch (`state`:
  `open` or `merged`, detected by the daemon or marked by a person).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "task_local_branches" do
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    belongs_to :task, Helmsman.Tasks.Task
    belongs_to :local_repository, Helmsman.LocalRepositories.LocalRepository
    field :branch, :string
    field :head_sha, :string
    field :state, :string, default: "open"
    field :merged_at, :utc_datetime
    belongs_to :merged_by, Helmsman.Actors.Actor
    field :merge_note, :string

    timestamps(type: :utc_datetime)
  end
end
