defmodule Helmsman.GitHub.PullRequests.Snapshot do
  @moduledoc """
  Step 1 of the reconciliation (`add-pr-reconcile-merge` decision 5): what
  the database says about a task, read in one short read-only
  transaction, in the shape `Helmsman.GitHub.PullRequests.Decide`
  expects. Only the repository the project is bound to now counts
  (decision 20).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Actors.Actor
  alias Helmsman.Config
  alias Helmsman.GitHub.{PullRequest, Repositories}
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.{GitRepo, Run}
  alias Helmsman.Squads
  alias Helmsman.Tasks.{Task, TaskEvent}
  alias Helmsman.Workspaces.Workspace

  @doc """
  The snapshot of `task_id` and the repository to call GitHub with
  (`%{repository, installation}`), or `:skip` when the task is gone or
  its project is not bound to a GitHub repository.
  """
  @spec load(pos_integer()) :: {:ok, map(), map()} | :skip
  def load(task_id) do
    {:ok, result} = Repo.transact(fn -> {:ok, read(task_id)} end)
    result
  end

  defp read(task_id) do
    with %Task{} = task <- Repo.get(Task, task_id),
         %Project{repository_id: repository_id} = project when repository_id != nil <-
           Repo.get(Project, task.project_id),
         {repository, installation} <- Repositories.get(task.workspace_id, repository_id) do
      branch = GitRepo.branch(task.workspace_id, task.ident)
      pushes = pushes(task.id, repository_id)

      snap = %{
        task: task_view(task),
        project: %{
          base_branch: project.base_branch || repository.default_branch,
          merge_policy: project.merge_policy,
          merge_method: project.merge_method,
          require_ci: project.require_ci,
          delete_branch_after_merge: project.delete_branch_after_merge
        },
        repository: %{
          id: repository.id,
          owner: repository.owner,
          name: repository.name,
          available?: Repositories.available?(repository, installation)
        },
        settings: settings(project),
        branch: branch,
        pr: current_pr(task.id, repository_id),
        pushes: pushes,
        latest_push: latest_push(pushes),
        active_run_id: active_run_id(task.id),
        verification: verification(task.id),
        assignee_side: Squads.assignee_side(task),
        max_auto_reopens: Config.max_auto_reopens(),
        public_url: Config.public_url()
      }

      snap = Map.put(snap, :squad_names, squad_names(snap))
      {:ok, snap, %{repository: repository, installation: installation}}
    else
      _ -> :skip
    end
  end

  @doc """
  The project's binding and merge settings the decision depends on; the
  reconciliation stops when they changed before a write
  (`Helmsman.GitHub.PullRequests.Reconcile`).
  """
  @spec settings(Project.t()) :: tuple()
  def settings(%Project{} = p),
    do:
      {p.repository_id, p.base_branch, p.merge_policy, p.merge_method, p.require_ci,
       p.delete_branch_after_merge}

  defp task_view(task) do
    %{
      id: task.id,
      ident: task.ident,
      title: task.title,
      body: task.description,
      status: task.status,
      assignee_id: task.assignee_id,
      workspace_id: task.workspace_id,
      project_id: task.project_id,
      slug: Repo.one!(from(w in Workspace, where: w.id == ^task.workspace_id, select: w.slug)),
      creator_name: Repo.one(from(a in Actor, where: a.id == ^task.created_by_id, select: a.name))
    }
  end

  @doc """
  The task's current pull request: its newest row in `repository_id`
  (decision 20), or nil.
  """
  @spec current_pr(pos_integer(), pos_integer() | nil) :: PullRequest.t() | nil
  def current_pr(_task_id, nil), do: nil

  def current_pr(task_id, repository_id) do
    Repo.one(
      from(p in PullRequest,
        where: p.task_id == ^task_id and p.repository_id == ^repository_id,
        order_by: [desc: p.id],
        limit: 1
      )
    )
  end

  @doc "The push records of `task_id` in `repository_id`, oldest first."
  @spec pushes(pos_integer(), pos_integer()) :: [map()]
  def pushes(task_id, repository_id) do
    Repo.all(
      from(r in Run,
        where:
          r.task_id == ^task_id and r.repository_id == ^repository_id and
            r.push_status in [:pushed, :conflict],
        order_by: [asc_nulls_first: r.claimed_at, asc: r.id],
        select: %{
          id: r.id,
          agent_id: r.agent_id,
          causal_agent_ids: r.causal_agent_ids,
          head_sha: r.head_sha,
          base_sha: r.base_sha,
          rescue_branch: r.rescue_branch,
          claimed_at: r.claimed_at
        }
      )
    )
  end

  defp latest_push(pushes),
    do: pushes |> Enum.filter(&is_nil(&1.rescue_branch)) |> List.last()

  defp active_run_id(task_id) do
    Repo.one(
      from(r in Run,
        where: r.task_id == ^task_id and r.status in ^Run.active_statuses(),
        order_by: [asc: r.id],
        limit: 1,
        select: r.id
      )
    )
  end

  # The names of the squads on the assignee side, then or now (`add-squads`
  # decision 11), for the decision's notes.
  defp squad_names(snap) do
    ids = snap.assignee_side ++ ((snap.verification && snap.verification.assignee_side_ids) || [])

    Repo.all(
      from(a in Actor,
        where: a.id in ^Enum.uniq(ids) and a.kind == :squad,
        select: {a.id, a.name}
      )
    )
    |> Map.new()
  end

  @doc "The latest move of `task_id` to `verified` in the shape of the decision, or nil."
  @spec verification(pos_integer()) :: map() | nil
  def verification(task_id) do
    Repo.one(
      from(e in TaskEvent,
        join: a in Actor,
        on: a.id == e.actor_id,
        left_join: r in Run,
        on: r.id == e.source_run_id,
        where: e.task_id == ^task_id and e.to_status == :verified,
        order_by: [desc: e.id],
        limit: 1,
        select: %{
          id: e.id,
          actor_id: a.id,
          actor_kind: a.kind,
          actor_name: a.name,
          verified_sha: e.verified_sha,
          assignee_side_ids: e.assignee_side_ids,
          run_causal_agent_ids: r.causal_agent_ids,
          inserted_at: e.inserted_at
        }
      )
    )
  end
end
