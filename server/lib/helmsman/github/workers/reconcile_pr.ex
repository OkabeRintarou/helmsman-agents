defmodule Helmsman.GitHub.Workers.ReconcilePR do
  @moduledoc """
  Reconciles the pull request of one task (`add-pr-reconcile-merge`
  decision 3): `Helmsman.GitHub.PullRequests.Reconcile.run/1`.

  Jobs of a task are unique while `available`, `scheduled` or
  `retryable` but not while `executing`, so a wake-up during a run queues
  the next one. Runs of a task are serial: the job checks out a connection
  for its whole duration (including the HTTP calls) and takes the
  session-level advisory lock of the task on it; another job of the task
  snoozes 5 seconds. The lock is released in `after`, and with the
  connection if the job's process dies (the pool does not reuse a
  connection whose owner crashed while holding it).

  Rate limits snooze until GitHub allows calls again; GitHub being
  unavailable returns an error (Oban's backoff).
  """

  use Oban.Worker,
    queue: :github_pr,
    max_attempts: 20,
    unique: [keys: [:task_id], states: [:available, :scheduled, :retryable]]

  alias Helmsman.GitHub.PullRequests.Reconcile
  alias Helmsman.Locks
  alias Helmsman.Repo

  @timeout_ms 5 * 60 * 1000

  @impl Oban.Worker
  def timeout(_job), do: @timeout_ms

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) when is_integer(task_id) do
    case serially(task_id, fn -> Reconcile.run(task_id) end) do
      :busy -> {:snooze, 5}
      {:error, {:rate_limited, retry_at}} -> {:snooze, max(DateTime.diff(retry_at, now()), 1)}
      other -> other
    end
  end

  @doc """
  Runs `fun` holding the reconciliation lock of `task_id` on a checked-out
  connection; `:busy` when another reconciliation of the task holds it.
  """
  @spec serially(pos_integer(), (-> result)) :: result | :busy when result: term()
  def serially(task_id, fun) do
    Repo.checkout(
      fn ->
        if Locks.try_session(:reconcile, task_id) do
          try do
            fun.()
          after
            unlock(task_id)
          end
        else
          :busy
        end
      end,
      timeout: @timeout_ms
    )
  end

  # A broken connection takes the lock with it.
  defp unlock(task_id) do
    Locks.unlock_session(:reconcile, task_id)
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> false
  end

  defp now, do: DateTime.utc_now()
end
