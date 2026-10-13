defmodule Helmsman.Tasks.VerifiedSha do
  @moduledoc """
  The commit recorded on a move to `verified` (`task_events.verified_sha`),
  shared by `add-pr-reconcile-merge` (its decision 15) and
  `add-local-repositories` (decision 10). Read inside the transition's
  transaction, after the task row is locked; never calls GitHub.

    * project bound to a GitHub repository: the head of the latest push
      of a run to the task branch in that repository (`latest_push/2`;
      pushes to other repositories, from before the project was bound to
      this one, and to rescue branches do not count); else nil;
    * project bound to a local repository: the task's
      `task_local_branches.head_sha`, when that row is on the project's
      current local repository; else nil;
    * no repository: nil.

  A project is bound to at most one of the two (`projects` check
  constraint). In local mode this is only a record: verifying merges
  nothing and changes nothing in the user's repository.
  """

  import Ecto.Query, warn: false

  alias Helmsman.LocalRepositories.TaskLocalBranch
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  @doc "The commit to record for `task` moving to `verified`, or nil."
  @spec compute(Task.t()) :: String.t() | nil
  def compute(%Task{id: task_id, project_id: project_id}) do
    case Repo.one(
           from(p in Project,
             where: p.id == ^project_id,
             select: {p.repository_id, p.local_repository_id}
           )
         ) do
      {repository_id, _} when not is_nil(repository_id) ->
        latest_push_head(task_id, repository_id)

      {nil, local_id} when not is_nil(local_id) ->
        local_head(task_id, local_id)

      _ ->
        nil
    end
  end

  @doc """
  The latest push of a run of `task_id` to its task branch in
  `repository_id` (`push_status` `pushed`), by `(claimed_at, id)`, or nil.
  """
  @spec latest_push(pos_integer(), pos_integer()) :: Run.t() | nil
  def latest_push(task_id, repository_id) do
    Repo.one(
      from(r in Run,
        where:
          r.task_id == ^task_id and r.repository_id == ^repository_id and
            r.push_status == :pushed,
        order_by: [desc_nulls_last: r.claimed_at, desc: r.id],
        limit: 1
      )
    )
  end

  defp latest_push_head(task_id, repository_id) do
    case latest_push(task_id, repository_id) do
      nil -> nil
      %Run{head_sha: head} -> head
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
