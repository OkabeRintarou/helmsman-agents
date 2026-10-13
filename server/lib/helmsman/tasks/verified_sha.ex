defmodule Helmsman.Tasks.VerifiedSha do
  @moduledoc """
  The commit recorded on a move to `verified` (`task_events.verified_sha`),
  shared by `add-pr-reconcile-merge` (its decision 15) and
  `add-local-repositories` (decision 10). Read inside the transition's
  transaction, after the task row is locked; never calls GitHub.

    * project bound to a local repository: the task's
      `task_local_branches.head_sha`, when that row is on the project's
      current local repository; else nil;
    * project bound to a GitHub repository: filled in by
      `add-pr-reconcile-merge` (nil until then);
    * no repository: nil.

  Only a record: in local mode verifying merges nothing and changes
  nothing in the user's repository.
  """

  import Ecto.Query, warn: false

  alias Helmsman.LocalRepositories.TaskLocalBranch
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Tasks.Task

  @doc "The commit to record for `task` moving to `verified`, or nil."
  @spec compute(Task.t()) :: String.t() | nil
  def compute(%Task{} = task) do
    case Repo.one(
           from(p in Project, where: p.id == ^task.project_id, select: p.local_repository_id)
         ) do
      nil -> nil
      local_id -> local_head(task.id, local_id)
    end
  end

  defp local_head(task_id, local_repository_id) do
    Repo.one(
      from(b in TaskLocalBranch,
        where: b.task_id == ^task_id and b.local_repository_id == ^local_repository_id,
        select: b.head_sha
      )
    )
  end
end
