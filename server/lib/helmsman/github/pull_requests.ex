defmodule Helmsman.GitHub.PullRequests do
  @moduledoc """
  Pull requests of tasks (`add-pr-reconcile-merge`, designs/15 §3–§6).

  Every change that may matter to a task's pull request only wakes its
  reconciliation (`wake/1`, `Helmsman.GitHub.Workers.ReconcilePR`), which
  reads the task and GitHub and acts. People can re-verify at the current
  commit, ask for a merge now (owners may skip the independence check)
  and restart the CI wait; these record the request and wake the
  reconciliation too (decisions 10, 11). `get/2` reads the current pull
  request for the task page; `{:pull_request_changed, ident}` on the task
  topic says it changed (decision 17).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Config
  alias Helmsman.Dispatch.Dependencies
  alias Helmsman.Events
  alias Helmsman.Feedback
  alias Helmsman.GitHub.{PullRequest, Repositories, Repository}
  alias Helmsman.GitHub.PullRequests.{Api, Decide, Reconcile, Snapshot}
  alias Helmsman.GitHub.Workers.ReconcilePR
  alias Helmsman.Policy
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Ident, Task, TaskEvent, VerifiedSha}
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  @max_reason_bytes 1000

  @type view :: map()

  ## Waking the reconciliation (decision 3)

  @doc """
  Wakes the reconciliation of `task_id`: a job to run now; an existing
  delayed one is brought forward. Inside a transaction the job is
  inserted with it.
  """
  @spec wake(pos_integer()) :: :ok
  def wake(task_id) when is_integer(task_id) do
    {:ok, _job} =
      Oban.insert(
        ReconcilePR.new(%{task_id: task_id},
          scheduled_at: DateTime.utc_now(),
          replace: [scheduled: [:scheduled_at]]
        )
      )

    :ok
  end

  @doc """
  Reconciles `task_id` again in `seconds`, unless a job of the task runs
  earlier already.
  """
  @spec poll(pos_integer(), pos_integer()) :: :ok
  def poll(task_id, seconds) when is_integer(task_id) and is_integer(seconds) do
    at = DateTime.add(DateTime.utc_now(), seconds)

    later? =
      Repo.exists?(
        from(j in Oban.Job,
          where:
            j.worker == "Helmsman.GitHub.Workers.ReconcilePR" and
              j.state in ["scheduled", "retryable"] and
              fragment("(?->>'task_id')::bigint", j.args) == ^task_id and j.scheduled_at > ^at
        )
      )

    opts =
      if later?,
        do: [scheduled_at: at, replace: [scheduled: [:scheduled_at]]],
        else: [scheduled_at: at]

    {:ok, _job} = Oban.insert(ReconcilePR.new(%{task_id: task_id}, opts))
    :ok
  end

  @doc """
  Wakes every task of project `project_id` that is `verified` and has an
  open pull request row in any repository, at most 500 (project settings
  changed, decision 4; the sweep catches the rest).
  """
  @spec wake_project(pos_integer()) :: :ok
  def wake_project(project_id) do
    from(t in Task,
      join: p in PullRequest,
      on: p.task_id == t.id,
      where: t.project_id == ^project_id and t.status == :verified and p.state in [:draft, :open],
      distinct: true,
      limit: 500,
      select: t.id
    )
    |> Repo.all()
    |> Enum.each(&wake/1)
  end

  @doc """
  The transition step (`Helmsman.Tasks.TransitionSteps`): wakes the
  reconciliation of a task whose project is bound to a GitHub repository,
  in the transition's transaction.
  """
  @spec after_transition(Task.t(), TaskEvent.t(), Scope.t()) :: :ok
  def after_transition(%Task{id: id}, _event, _scope), do: wake_if_bound(id)

  @doc """
  Wakes the task of `task_id` when its project is bound to a GitHub
  repository (decision 4); nil does nothing.
  """
  @spec wake_if_bound(pos_integer() | nil) :: :ok
  def wake_if_bound(nil), do: :ok

  def wake_if_bound(task_id) do
    bound? =
      Repo.exists?(
        from(t in Task,
          join: p in Project,
          on: p.id == t.project_id,
          where: t.id == ^task_id and not is_nil(p.repository_id)
        )
      )

    if bound?, do: wake(task_id), else: :ok
  end

  ## Reading (decision 17)

  @doc """
  The current pull request of task `ident` (`:read_tasks`), or nil: its
  number, link, state, branches, head, checks (decision 22: nil when read
  for another head), merge status, reason and note, merge commit and time,
  reopens, the commit of the latest verification, and what the scope's
  user can do (`can`: `reverify`, `merge_now`, `skip_independence`,
  `retry`).
  """
  @spec get(Scope.t(), String.t()) :: {:ok, view() | nil} | {:error, :forbidden | :not_found}
  def get(%Scope{} = scope, ident) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, task} <- fetch_task(scope, ident) do
      {:ok, view(scope, task)}
    end
  end

  @doc "Whether the current pull request of `task_id` is merged."
  @spec merged?(pos_integer()) :: boolean()
  def merged?(task_id) do
    case current_row(task_id) do
      %PullRequest{state: :merged} -> true
      _other -> false
    end
  end

  @doc """
  The dependency hook (decisions 17, 21): called inside the transaction
  that records a pull request of `task_id` merged for the first time, or
  a new `included_sha`, so whatever it writes (`add-dependency-dispatch`
  inserts its re-check job here) commits or rolls back with that fact:
  the `[:helmsman, :pull_requests, :after_merge]` telemetry event
  (handlers run inside the transaction) and
  `Helmsman.Dispatch.Dependencies.changed/1`.
  """
  @spec after_merge(pos_integer()) :: :ok
  def after_merge(task_id) do
    test_hook({:after_merge, task_id})
    :telemetry.execute([:helmsman, :pull_requests, :after_merge], %{}, %{task_id: task_id})
    Dependencies.changed(task_id)
  end

  # Test hook: a failure of the dependency hook rolls the fact back.
  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _ -> :ok
      end
    end
  else
    defp test_hook(_point), do: :ok
  end

  @doc """
  What verifying task `ident` as the scope's identity now would lead to
  (`:read_tasks`; `add-github-ui` R3): nil without a GitHub repository,
  else `%{verified_sha, checks_state, base_branch, outcome}`, `outcome`
  one of `auto_merge`, `policy_manual`, `agent_verified`,
  `not_independent`, `no_commit`, `repository_unavailable`. Reads the
  database only; CI, the head and the push chain are judged at merge
  time.
  """
  @spec verify_preview(Scope.t(), String.t()) ::
          {:ok, map() | nil} | {:error, :forbidden | :not_found}
  def verify_preview(%Scope{actor: %Actor{} = actor} = scope, ident) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, task} <- fetch_task(scope, ident) do
      project = Repo.get!(Project, task.project_id)
      {:ok, preview(scope, actor, task, project)}
    end
  end

  defp preview(_scope, _actor, _task, %Project{repository_id: nil}), do: nil

  defp preview(scope, actor, task, project) do
    {repository, installation} = Repositories.get(task.workspace_id, project.repository_id)
    row = current_row(task.id)
    verified_sha = VerifiedSha.compute(task)

    v = %{
      id: nil,
      actor_id: actor.id,
      actor_kind: actor.kind,
      actor_name: actor.name,
      verified_sha: verified_sha,
      run_causal_agent_ids: run_causal_ids(scope)
    }

    snap = %{
      task: %{assignee_id: task.assignee_id},
      pushes: Snapshot.pushes(task.id, project.repository_id)
    }

    %{
      verified_sha: verified_sha,
      checks_state: if(row, do: Atom.to_string(row.checks_state), else: "none"),
      base_branch: project.base_branch || repository.default_branch,
      outcome:
        if(Repositories.available?(repository, installation),
          do: outcome(project, actor, snap, v),
          else: "repository_unavailable"
        )
    }
  end

  # Decision 7 steps 1–3 for the scope's identity.
  defp outcome(project, actor, snap, v) do
    cond do
      project.merge_policy == "manual" -> "policy_manual"
      project.merge_policy == "on_verified_human" and actor.kind != :human -> "agent_verified"
      Decide.independence(snap, v) != :ok -> "not_independent"
      v.verified_sha == nil -> "no_commit"
      true -> "auto_merge"
    end
  end

  defp run_causal_ids(%Scope{run: %Run{causal_agent_ids: ids}}), do: ids || []
  defp run_causal_ids(_scope), do: []

  ## People's requests (decisions 10, 11, 14)

  @doc """
  Re-verifies task `ident` at its pull request's current head
  (`:merge_pull_request`, decision 10): a new `verified → verified`
  history entry by the scope's identity with that commit and a `review`
  saying so, which becomes the verification the merge is judged by.

  `opts[:expected_head_sha]`: the head the person confirmed; when GitHub's
  head differs, `{:error, {:head_changed, head}}` and nothing is written.
  `opts[:expected_pull_request]`: the pull request the person confirmed,
  checked as in `merge_now/3` (before calling GitHub, then again under
  the row lock).

  Errors: `{:pull_request_changed, identity | nil}`,
  `:invalid_expected_pull_request`, `{:invalid_status, status}` (not verified), `:not_reverifiable`
  (no open current pull request, or one neither `stale` nor blocked for a
  missing or foreign verified commit), `:not_pushed_by_run` (the head is
  not the latest push of a run), `{:run_active, %{id, agent}}`,
  `:forbidden`, `:not_found`, `{:head_changed, head}`, GitHub errors.
  Returns the pull request view read after the write.
  """
  @spec reverify(Scope.t(), String.t(), keyword()) :: {:ok, view()} | {:error, term()}
  def reverify(%Scope{} = scope, ident, opts \\ []) do
    with :ok <- Policy.authorize(scope, :merge_pull_request),
         {:ok, expected} <- expected_pull_request(opts),
         {:ok, task} <- fetch_task(scope, ident),
         :ok <- check_expected(expected, current_row(task.id)),
         {:ok, row, repo} <- open_row(task),
         {:ok, facts} <- Api.get(repo, row.number),
         :ok <- expected_head(opts[:expected_head_sha], facts.head_sha) do
      Workspaces.write_transaction(scope, :merge_pull_request, fn scope ->
        reverify_locked(scope, task, {row, expected}, facts.head_sha)
      end)
    end
  end

  defp expected_head(nil, _head), do: :ok
  defp expected_head(head, head), do: :ok
  defp expected_head(_expected, head), do: {:error, {:head_changed, head}}

  defp reverify_locked(scope, task, {row_seen, expected}, head) do
    test_hook(:reverify_locking)
    task = lock_task(task.id)
    row = lock_current_row(task)

    case reverify_check(task, row, {row_seen, expected}, head) do
      {:error, _reason} = error ->
        error

      :ok ->
        {:ok, {entry, task}} =
          Feedback.insert_locked(task, scope, %{
            kind: :review,
            content: "Re-verified at #{Decide.short(head)}."
          })

        event =
          Repo.insert!(%TaskEvent{
            workspace_id: task.workspace_id,
            task_id: task.id,
            from_status: :verified,
            to_status: :verified,
            actor_id: scope.actor.id,
            commits: [],
            auto: false,
            verified_sha: head,
            # `add-squads` decision 11: who was on the assignee side.
            assignee_side_ids: Helmsman.Squads.assignee_side(task),
            feedback_id: entry.id,
            source_run_id: source_run_id(scope)
          })

        Tasks.notify_summary(task)

        Events.after_commit(
          Events.topic(:task, task.id),
          {:task_transitioned,
           %{
             ident: task.ident,
             event:
               Tasks.event_view(%{
                 event
                 | actor: scope.actor,
                   feedback_ident: Feedback.Id.build(task.ident, entry.seq)
               })
           }}
        )

        wake(task.id)
        {:ok, view(scope, task)}
    end
  end

  defp reverify_check(task, row, {row_seen, expected}, head) do
    cond do
      changed = changed_pull_request(expected, row) ->
        changed

      task.status != :verified ->
        {:error, {:invalid_status, task.status}}

      not reverifiable_row?(row, row_seen) ->
        {:error, :not_reverifiable}

      head != latest_push_head(task, row) ->
        {:error, :not_pushed_by_run}

      run = Helmsman.Runs.active_on_task(task.id, nil) ->
        {:error, {:run_active, run}}

      true ->
        :ok
    end
  end

  defp reverifiable_row?(nil, _row_seen), do: false

  defp reverifiable_row?(row, row_seen),
    do: row.id == row_seen.id and PullRequest.open?(row) and reverifiable?(row)

  defp reverifiable?(%PullRequest{merge_status: :stale}), do: true

  defp reverifiable?(%PullRequest{merge_reason: reason}),
    do: reason in [:verified_sha_missing, :verified_sha_not_pushed]

  defp latest_push_head(task, row) do
    case VerifiedSha.latest_push(task.id, row.repository_id) do
      nil -> nil
      run -> run.head_sha
    end
  end

  defp source_run_id(%Scope{via: :run, run: %{id: id}}), do: id
  defp source_run_id(_scope), do: nil

  @doc """
  Asks for a merge of task `ident` now (`:merge_pull_request`, decision
  11): the request is recorded on the current pull request for the latest
  verification and lets the merge policy through; with
  `opts[:skip_independence]` (a reason of 1–#{@max_reason_bytes} bytes,
  owners only, else `:forbidden`) the independence check is skipped and
  the system writes a comment with the reason. The other preconditions
  hold as for automatic merges; the reconciliation decides.

  `opts[:expected_pull_request]` (`%{repository: full_name, number: n}`,
  the `repository.full_name` and `number` of the view the person
  confirmed): compared, in the transaction and after the current pull
  request row is locked `FOR UPDATE`, with the current pull request (the
  project's repository now). Another one, or none, is
  `{:error, {:pull_request_changed, %{repository, number} | nil}}` and
  nothing is written. Without it, the current pull request is used.

  Errors: `{:pull_request_changed, identity | nil}`,
  `:invalid_expected_pull_request`, `{:invalid_status, status}`,
  `:no_pull_request`, `:invalid_reason`, `:forbidden`, `:not_found`.
  """
  @spec merge_now(Scope.t(), String.t(), keyword()) :: {:ok, view()} | {:error, term()}
  def merge_now(%Scope{} = scope, ident, opts \\ []) do
    with :ok <- Policy.authorize(scope, :merge_pull_request),
         {:ok, reason} <- skip_reason(opts[:skip_independence]),
         {:ok, expected} <- expected_pull_request(opts),
         {:ok, task} <- fetch_task(scope, ident) do
      Workspaces.write_transaction(scope, :merge_pull_request, fn scope ->
        merge_now_locked(scope, task, reason, expected)
      end)
    end
  end

  # The pull request a person confirmed (add-github-ui code review 3).
  defp expected_pull_request(opts) do
    case opts[:expected_pull_request] do
      nil ->
        {:ok, nil}

      %{repository: repository, number: number} = expected
      when is_binary(repository) and is_integer(number) ->
        {:ok, Map.take(expected, [:repository, :number])}

      _other ->
        {:error, :invalid_expected_pull_request}
    end
  end

  defp check_expected(expected, row) do
    case changed_pull_request(expected, row) do
      nil -> :ok
      changed -> changed
    end
  end

  # nil when nothing was expected or `row` is the expected pull request.
  defp changed_pull_request(nil, _row), do: nil

  defp changed_pull_request(expected, row) do
    case identity(row) do
      ^expected -> nil
      current -> {:error, {:pull_request_changed, current}}
    end
  end

  defp identity(nil), do: nil

  defp identity(%PullRequest{} = row),
    do: %{
      repository: Repository.full_name(Repo.get!(Repository, row.repository_id)),
      number: row.number
    }

  defp skip_reason(nil), do: {:ok, nil}

  defp skip_reason(reason) when is_binary(reason) do
    reason = String.trim(reason)

    if reason != "" and byte_size(reason) <= @max_reason_bytes,
      do: {:ok, reason},
      else: {:error, :invalid_reason}
  end

  defp skip_reason(_reason), do: {:error, :invalid_reason}

  defp merge_now_locked(scope, task, reason, expected) do
    task = lock_task(task.id)
    row = lock_current_row(task)
    v = Snapshot.verification(task.id)

    cond do
      reason != nil and scope.role != :owner ->
        {:error, :forbidden}

      changed = changed_pull_request(expected, row) ->
        changed

      task.status != :verified or v == nil ->
        {:error, {:invalid_status, task.status}}

      not PullRequest.open?(row) ->
        {:error, :no_pull_request}

      true ->
        request = %{
          "by_actor_id" => scope.actor.id,
          "verification_event_id" => v.id,
          "skip_independence_reason" => reason,
          "at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        Reconcile.update_row(row, [merge_request: request], task)
        if reason, do: skip_comment(task, scope, reason)
        wake(task.id)
        {:ok, view(scope, task)}
    end
  end

  defp skip_comment(task, scope, reason) do
    system =
      Repo.one!(
        from(a in Actor, where: a.workspace_id == ^task.workspace_id and a.kind == :system)
      )

    {:ok, {_entry, task}} =
      Feedback.insert_locked(task, %Scope{workspace: scope.workspace, actor: system}, %{
        kind: :comment,
        content: "#{scope.actor.name} asked to merge without the independence check: #{reason}"
      })

    Tasks.notify_summary(task)
  end

  @doc """
  Restarts the CI wait of task `ident`'s current pull request and wakes
  the reconciliation (`:merge_pull_request`, decision 11).
  Errors: `{:invalid_status, status}`, `:no_pull_request`, `:forbidden`,
  `:not_found`.
  """
  @spec retry(Scope.t(), String.t()) :: {:ok, view()} | {:error, term()}
  def retry(%Scope{} = scope, ident) do
    with :ok <- Policy.authorize(scope, :merge_pull_request),
         {:ok, task} <- fetch_task(scope, ident) do
      Workspaces.write_transaction(scope, :merge_pull_request, &retry_locked(&1, task))
    end
  end

  defp retry_locked(scope, task) do
    task = lock_task(task.id)
    row = lock_current_row(task)

    cond do
      task.status != :verified ->
        {:error, {:invalid_status, task.status}}

      not PullRequest.open?(row) ->
        {:error, :no_pull_request}

      true ->
        Reconcile.update_row(row, [waiting_since: nil], task)
        wake(task.id)
        {:ok, view(scope, task)}
    end
  end

  ## Helpers

  defp fetch_task(%Scope{workspace: %Workspace{id: workspace_id}}, ident) when is_binary(ident) do
    with {:ok, ident, _key, _seq} <- Ident.parse(ident),
         %Task{} = task <-
           Repo.one(from(t in Task, where: t.workspace_id == ^workspace_id and t.ident == ^ident)) do
      {:ok, task}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_task(_scope, _ident), do: {:error, :not_found}

  defp project_repository_id(%Task{project_id: project_id}),
    do: Repo.one!(from(p in Project, where: p.id == ^project_id, select: p.repository_id))

  defp current_row(task_id) do
    task = Repo.get!(Task, task_id)
    Snapshot.current_pr(task.id, project_repository_id(task))
  end

  defp open_row(task) do
    with repository_id when repository_id != nil <- project_repository_id(task),
         %PullRequest{} = row <- Snapshot.current_pr(task.id, repository_id),
         true <- PullRequest.open?(row),
         {:ok, {repository, installation}} <-
           Repositories.fetch_available(task.workspace_id, repository_id) do
      {:ok, row, %{repository: repository, installation: installation}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :not_reverifiable}
    end
  end

  # Lock order: maintenance lock and membership row (the caller), task
  # row, pull request row.
  defp lock_task(task_id),
    do: Repo.one!(from(t in Task, where: t.id == ^task_id, lock: "FOR UPDATE"))

  defp lock_current_row(task) do
    case project_repository_id(task) do
      nil ->
        nil

      repository_id ->
        Repo.one(
          from(p in PullRequest,
            where: p.task_id == ^task.id and p.repository_id == ^repository_id,
            order_by: [desc: p.id],
            limit: 1,
            lock: "FOR UPDATE"
          )
        )
    end
  end

  defp view(scope, task) do
    case current_row(task.id) do
      nil -> nil
      row -> build_view(scope, task, row)
    end
  end

  defp build_view(scope, task, row) do
    v = Snapshot.verification(task.id)
    repository = Repo.get!(Repository, row.repository_id)
    may? = Policy.authorize(scope, :merge_pull_request) == :ok
    actionable? = may? and task.status == :verified and PullRequest.open?(row)

    %{
      number: row.number,
      url: row.url,
      repository: %{full_name: Repository.full_name(repository)},
      state: Atom.to_string(row.state),
      branch: row.branch,
      base_branch: row.base_branch,
      head_sha: row.head_sha,
      checks_state: Atom.to_string(row.checks_state),
      checks: checks_view(row),
      merge_status: Atom.to_string(row.merge_status),
      merge_reason: row.merge_reason && Atom.to_string(row.merge_reason),
      merge_note: row.merge_note,
      merged_sha: row.merged_sha,
      merged_at: row.merged_at,
      waiting_since: row.waiting_since,
      auto_reopen_count: row.auto_reopen_count,
      max_auto_reopens: Config.max_auto_reopens(),
      verified_sha: v && v.verified_sha,
      merge_request: merge_request_view(row, v),
      can: %{
        reverify: actionable? and reverifiable?(row),
        merge_now: actionable?,
        skip_independence: actionable? and scope.role == :owner,
        retry: actionable?
      }
    }
  end

  defp checks_view(%PullRequest{checks: %{"head_sha" => head} = checks, head_sha: head}) do
    %{
      head_sha: head,
      total: checks["total"],
      passed: checks["passed"],
      pending: checks["pending"],
      failed: checks["failed"]
    }
  end

  defp checks_view(_row), do: nil

  defp merge_request_view(row, v) do
    case Decide.merge_request(row, v) do
      nil ->
        nil

      request ->
        by = request["by_actor_id"] && Repo.get(Actor, request["by_actor_id"])

        %{
          by: by && %{name: by.name, kind: Atom.to_string(by.kind)},
          at: request["at"],
          skip_independence?: is_binary(request["skip_independence_reason"])
        }
    end
  end
end
