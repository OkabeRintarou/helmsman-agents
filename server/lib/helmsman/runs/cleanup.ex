defmodule Helmsman.Runs.Cleanup do
  @moduledoc """
  Which task worktrees a daemon may delete (`add-pr-reconcile-merge`
  decision 16, server part; worktree-cleanup "服务端的清理判定").

  An item `{workspace_id, ident}` (the ident as the worktree's directory
  name, any case) is deletable when the daemon still serves the workspace
  (it selected it and its user is a member or above), the task exists and
  is `verified`, `cancelled` or `rejected`, no run of it is `deferred`,
  `queued`, `claimed`, `running` or `cancelling`, and — when a run pushed
  to the repository the project is bound to now — the current pull request
  there is merged or closed (no pull request row: not yet). Pushes to
  other repositories do not matter: no run pushes there any more.

  Each result carries `pushed_heads`, the heads of every push record of
  the task (any repository, rescue branches too), newest first, at most
  200, and `base_branch`, the project's base branch or else the default
  branch of its GitHub or local repository. Projects bound to a local
  repository (`add-local-repositories`) have no pull requests: only the
  task status and its runs count. Read-only, in one short transaction that
  locks the daemon row `FOR SHARE` (authorization epoch checked).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Daemons.DaemonWorkspace
  alias Helmsman.GitHub.{PullRequest, Repository}
  alias Helmsman.LocalRepositories.LocalRepository
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.{Lifecycle, Run}
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.Tx
  alias Helmsman.Workspaces.Membership

  @max_heads 200
  @member_roles [:owner, :admin, :member]
  @open_runs [:deferred, :queued, :claimed, :running, :cancelling]
  @closed_tasks [:verified, :cancelled, :rejected]

  @type item :: %{workspace_id: pos_integer(), ident: String.t()}
  @type result :: %{
          workspace_id: pos_integer(),
          ident: String.t(),
          deletable: boolean(),
          base_branch: String.t() | nil,
          pushed_heads: [String.t()]
        }

  @doc "Judges `items` for the daemon of `ctx`; one result per item, in order."
  @spec check(Lifecycle.daemon_ctx(), [item()]) :: {:ok, [result()]} | {:error, :reauthorized}
  def check(ctx, items) do
    Tx.run(fn ->
      with {:ok, daemon} <- Lifecycle.lock_daemon(ctx) do
        {:ok, judge(daemon, items)}
      end
    end)
  end

  defp judge(daemon, items) do
    served = served(daemon)

    keys =
      for %{workspace_id: wid, ident: ident} <- items,
          MapSet.member?(served, wid),
          {:ok, ident, _key, _seq} <- [Ident.parse(ident)],
          uniq: true,
          do: {wid, ident}

    tasks = tasks(keys)
    task_ids = Enum.map(tasks, fn {_key, task} -> task.id end)
    open = open_runs(task_ids)
    heads = heads(task_ids)
    projects = projects(tasks)

    Enum.map(items, fn %{workspace_id: wid, ident: ident} ->
      task = with {:ok, canonical, _, _} <- Ident.parse(ident), do: tasks[{wid, canonical}]

      case task do
        %Task{} ->
          project = projects[task.project_id]

          %{
            workspace_id: wid,
            ident: ident,
            deletable: deletable?(task, project, open),
            base_branch: project.base_branch,
            pushed_heads: Map.get(heads, task.id, [])
          }

        _ ->
          %{workspace_id: wid, ident: ident, deletable: false, base_branch: nil, pushed_heads: []}
      end
    end)
  end

  defp served(daemon) do
    from(dw in DaemonWorkspace,
      join: m in Membership,
      on: m.workspace_id == dw.workspace_id and m.user_id == ^daemon.user_id,
      where: dw.daemon_id == ^daemon.id and m.role in ^@member_roles,
      select: dw.workspace_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp tasks([]), do: %{}

  defp tasks(keys) do
    {wids, idents} = Enum.unzip(keys)

    from(t in Task,
      join:
        k in fragment(
          "SELECT * FROM unnest(?::bigint[], ?::text[]) AS k(wid, ident)",
          ^wids,
          ^idents
        ),
      on: t.workspace_id == k.wid and t.ident == k.ident
    )
    |> Repo.all()
    |> Map.new(&{{&1.workspace_id, &1.ident}, &1})
  end

  defp open_runs(task_ids) do
    from(r in Run, where: r.task_id in ^task_ids and r.status in ^@open_runs, select: r.task_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # Every push of the tasks, newest first, at most @max_heads per task.
  defp heads(task_ids) do
    ranked =
      from(r in Run,
        where: r.task_id in ^task_ids and r.push_status in [:pushed, :conflict],
        select: %{
          task_id: r.task_id,
          head_sha: r.head_sha,
          n:
            over(row_number(),
              partition_by: r.task_id,
              order_by: [desc_nulls_last: r.claimed_at, desc: r.id]
            )
        }
      )

    from(x in subquery(ranked), where: x.n <= @max_heads, order_by: [x.task_id, x.n])
    |> Repo.all()
    |> Enum.group_by(& &1.task_id, & &1.head_sha)
  end

  # The GitHub repository and base branch of each task's project (a
  # project is bound to at most one of a GitHub and a local repository).
  defp projects(tasks) do
    project_ids = tasks |> Map.values() |> Enum.map(& &1.project_id) |> Enum.uniq()

    from(p in Project,
      left_join: r in Repository,
      on: r.id == p.repository_id,
      left_join: l in LocalRepository,
      on: l.id == p.local_repository_id,
      where: p.id in ^project_ids,
      select:
        {p.id,
         %{
           repository_id: p.repository_id,
           base_branch: coalesce(p.base_branch, coalesce(r.default_branch, l.default_branch))
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp deletable?(task, project, open) do
    task.status in @closed_tasks and not MapSet.member?(open, task.id) and
      pull_request_done?(task, project.repository_id)
  end

  defp pull_request_done?(_task, nil), do: true

  defp pull_request_done?(task, repository_id) do
    pushed? =
      Repo.exists?(
        from(r in Run,
          where:
            r.task_id == ^task.id and r.repository_id == ^repository_id and
              r.push_status in [:pushed, :conflict]
        )
      )

    state =
      Repo.one(
        from(p in PullRequest,
          where: p.task_id == ^task.id and p.repository_id == ^repository_id,
          order_by: [desc: p.id],
          limit: 1,
          select: p.state
        )
      )

    not pushed? or state in [:merged, :closed]
  end
end
