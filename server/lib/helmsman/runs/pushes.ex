defmodule Helmsman.Runs.Pushes do
  @moduledoc """
  The git messages of a daemon about the runs it claimed
  (`add-daemon-git-workspace` decisions 4, 5): renewing a push token and
  recording a push.

  Both lock only the daemon row `FOR SHARE` (revoked or another
  authorization epoch: `{:error, :reauthorized}`) and then the run row
  (not claimed by this daemon: `{:error, :not_found}`), as the other
  reports do (`Helmsman.Runs.Lifecycle`). GitHub is only called after the
  transaction.
  """

  import Ecto.Query, warn: false

  alias Helmsman.GitHub
  alias Helmsman.GitHub.Repository
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Lifecycle, Run}
  alias Helmsman.Tx
  alias HelmsmanProtocol.Report

  @late_seconds 30 * 60
  @max_commits 250
  @max_subject_bytes 1024
  @sha ~r/\A[0-9a-f]{40}\z/

  ## git_token

  @doc """
  A new push token for `run_id` (decision 4): the run must have been
  claimed by this daemon and have a repository (`:not_found` otherwise),
  and be `claimed`, `running`, `cancelling` or have ended less than 30
  minutes ago (late wrap-up; `:wrong_state` otherwise). A repository no
  longer available or GitHub unreachable: `{:unavailable, message}`.
  """
  @spec git_token(Lifecycle.daemon_ctx(), pos_integer()) ::
          {:ok, %{token: String.t(), expires_at: DateTime.t()}}
          | {:error, :not_found | :wrong_state | :reauthorized | {:unavailable, String.t()}}
  def git_token(ctx, run_id) do
    result =
      Tx.run(fn ->
        with {:ok, _daemon} <- Lifecycle.lock_daemon(ctx),
             {:ok, run} <- Lifecycle.lock_run(ctx, run_id, :share),
             {:ok, repository_id} <- repository_id(run),
             :ok <- token_window(run) do
          {:ok, Repo.get!(Repository, repository_id)}
        end
      end)

    with {:ok, repository} <- result, do: push_token(repository)
  end

  defp repository_id(%Run{repository_id: nil}), do: {:error, :not_found}
  defp repository_id(%Run{repository_id: id}), do: {:ok, id}

  defp token_window(%Run{status: status}) when status in [:claimed, :running, :cancelling],
    do: :ok

  defp token_window(%Run{finished_at: %DateTime{} = finished_at}) do
    if DateTime.diff(DateTime.utc_now(), finished_at) < @late_seconds,
      do: :ok,
      else: {:error, :wrong_state}
  end

  defp token_window(_run), do: {:error, :wrong_state}

  defp push_token(repository) do
    case GitHub.push_token(repository) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        {:ok, %{token: token, expires_at: expires_at}}

      {:error, reason} when reason in [:repository_unavailable, :not_found] ->
        {:error, {:unavailable, "repository is not available"}}

      {:error, _reason} ->
        {:error, {:unavailable, "GitHub is unavailable, retry later"}}
    end
  end

  ## pushed

  @doc """
  Records a push of the run (decision 5), whatever its status: the push
  happened on the remote. The run must have been claimed by this daemon
  (`:not_found`) and have a repository (`:wrong_state`). The report must
  name its task branch, a rescue branch `<branch>-run-<n>` of a run of
  the same task claimed by this daemon, 40-character lower-case SHAs, at
  most #{@max_commits} commits with subjects of at most #{@max_subject_bytes} bytes
  (`{:invalid_payload, why}`, nothing written).

  Without a push record yet (`pushed_at` nil): `pushed` (or `conflict`
  with a rescue branch) and the record; the run's status and failure
  reason do not change. The same `head_sha` and rescue branch again: `:ok`
  without a write; others: `:wrong_state`. After the commit the run's
  topics are notified and `Helmsman.Runs.after_push/1` is called.
  """
  @spec pushed(Lifecycle.daemon_ctx(), Report.Pushed.t()) :: :ok | {:error, Lifecycle.error()}
  def pushed(ctx, %Report.Pushed{run_id: run_id} = report) do
    result =
      Tx.run(fn ->
        with {:ok, _daemon} <- Lifecycle.lock_daemon(ctx),
             {:ok, run} <- Lifecycle.lock_run(ctx, run_id),
             {:ok, _id} <- with_repository(run),
             :ok <- validate(run, report, ctx.daemon_id) do
          record(run, report)
        end
      end)

    with {:ok, :ok} <- result, do: :ok
  end

  defp with_repository(%Run{repository_id: nil}), do: {:error, :wrong_state}
  defp with_repository(%Run{repository_id: id}), do: {:ok, id}

  defp validate(run, report, daemon_id) do
    cond do
      report.branch != run.branch -> invalid(:branch)
      not rescue_branch?(run, report.rescue_branch, daemon_id) -> invalid(:rescue_branch)
      not sha?(report.base_sha) or not sha?(report.head_sha) -> invalid(:sha)
      length(report.commits) > @max_commits -> invalid(:commits)
      not Enum.all?(report.commits, &commit?/1) -> invalid(:commits)
      true -> :ok
    end
  end

  defp invalid(why), do: {:error, {:invalid_payload, why}}

  defp sha?(sha), do: is_binary(sha) and Regex.match?(@sha, sha)

  defp commit?(%{sha: sha, subject: subject}),
    do: sha?(sha) and is_binary(subject) and byte_size(subject) <= @max_subject_bytes

  defp rescue_branch?(_run, nil, _daemon_id), do: true

  defp rescue_branch?(%Run{branch: branch, task_id: task_id}, rescue_branch, daemon_id) do
    prefix = branch <> "-run-"

    with ^prefix <> n <- rescue_branch,
         {id, ""} when id > 0 <- Integer.parse(n),
         true <- Integer.to_string(id) == n do
      Repo.exists?(
        from(r in Run, where: r.id == ^id and r.task_id == ^task_id and r.daemon_id == ^daemon_id)
      )
    else
      _invalid -> false
    end
  end

  defp record(%Run{pushed_at: nil} = run, report) do
    run =
      Lifecycle.update!(run,
        push_status: if(report.rescue_branch, do: :conflict, else: :pushed),
        base_sha: report.base_sha,
        head_sha: report.head_sha,
        rescue_branch: report.rescue_branch,
        push_commits: Enum.map(report.commits, &%{"sha" => &1.sha, "subject" => &1.subject}),
        pushed_at: DateTime.utc_now()
      )

    Tx.after_commit(fn -> Runs.after_push(run) end)
    {:ok, :ok}
  end

  defp record(%Run{head_sha: head, rescue_branch: same}, %{head_sha: head, rescue_branch: same}),
    do: {:ok, :ok}

  defp record(_run, _report), do: {:error, :wrong_state}
end
