defmodule Helmsman.GitHub.Workers.ReconcileSweep do
  @moduledoc """
  Every 15 minutes (`add-pr-reconcile-merge` decision 4): wakes the
  reconciliation of tasks that may have missed a wake-up, at most
  200 per round, those reconciled longest ago (never first):

    * the current pull request is a draft or open and the task is
      `verified` or its merge status is `waiting`;
    * a run pushed to the task branch in the project's current repository
      in the last 7 days and that repository has no draft or open pull
      request row of the task.
  """

  use Oban.Worker, queue: :github, max_attempts: 3

  alias Helmsman.GitHub.PullRequests
  alias Helmsman.Repo

  @limit 200

  @sql """
  WITH cur AS (
    SELECT DISTINCT ON (p.task_id) p.task_id, p.state, p.merge_status, p.reconciled_at
    FROM task_pull_requests p
    JOIN tasks t ON t.id = p.task_id
    JOIN projects pj ON pj.id = t.project_id
    WHERE p.repository_id = pj.repository_id
    ORDER BY p.task_id, p.id DESC
  ),
  candidates AS (
    SELECT cur.task_id, cur.reconciled_at
    FROM cur
    JOIN tasks t ON t.id = cur.task_id
    WHERE cur.state IN ('draft', 'open')
      AND (t.status = 'verified' OR cur.merge_status = 'waiting')
    UNION
    SELECT DISTINCT r.task_id, cur.reconciled_at
    FROM runs r
    JOIN tasks t ON t.id = r.task_id
    JOIN projects pj ON pj.id = t.project_id
    LEFT JOIN cur ON cur.task_id = r.task_id
    WHERE r.repository_id = pj.repository_id
      AND r.push_status = 'pushed'
      AND r.pushed_at > now() - interval '7 days'
      AND NOT EXISTS (
        SELECT 1 FROM task_pull_requests o
        WHERE o.task_id = r.task_id AND o.repository_id = pj.repository_id
          AND o.state IN ('draft', 'open')
      )
  )
  SELECT task_id FROM candidates
  GROUP BY task_id
  ORDER BY min(reconciled_at) NULLS FIRST, task_id
  LIMIT $1
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Enum.each(due(), &PullRequests.wake/1)
  end

  @doc "The IDs of the tasks to wake, in order, at most `limit`."
  @spec due(pos_integer()) :: [pos_integer()]
  def due(limit \\ @limit) do
    %{rows: rows} = Repo.query!(@sql, [limit])
    Enum.map(rows, fn [id] -> id end)
  end
end
