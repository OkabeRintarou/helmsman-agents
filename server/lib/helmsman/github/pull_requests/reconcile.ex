defmodule Helmsman.GitHub.PullRequests.Reconcile do
  @moduledoc """
  One reconciliation of a task's pull request (`add-pr-reconcile-merge`
  decision 5):

    1. the snapshot (`Helmsman.GitHub.PullRequests.Snapshot`);
    2. what GitHub says now: the current row's pull request, an open one
       of the task branch not recorded yet, the checks of the head, the
       compare of the verified push chain's end and of the latest push
       against a merged head (`read_github/2`);
    3. the decision (`Helmsman.GitHub.PullRequests.Decide`);
    4. the actions: every GitHub write runs outside any transaction and
       its result is recorded in a short one (maintenance lock shared,
       task row `FOR SHARE`, pull request row `FOR UPDATE`). When the
       task's status or latest verification changed since the snapshot,
       only GitHub's facts are recorded and the remaining actions are
       skipped;
    5. after any GitHub write the task is woken again; `reconciled_at` is
       written every time.

  Called by `Helmsman.GitHub.Workers.ReconcilePR` holding the task's
  reconciliation lock.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Feedback
  alias Helmsman.GitHub.PullRequest
  alias Helmsman.GitHub.PullRequests
  alias Helmsman.GitHub.PullRequests.{Api, Decide, Snapshot}
  alias Helmsman.Locks
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Task, TaskEvent}
  alias Helmsman.Tx
  alias Helmsman.Workspaces.Workspace

  # Changes that describe GitHub (or the pushes), recorded even when the
  # task moved on since the snapshot.
  @fact_keys [
    :state,
    :head_sha,
    :merged_at,
    :merged_sha,
    :included_sha,
    :checks_state,
    :checks,
    :closed_by_helmsman,
    :draft_supported,
    :branch_deleted_at,
    :rescue_cleaned_at
  ]

  @doc "Reconciles the pull request of `task_id`; see the module documentation."
  @spec run(pos_integer()) :: :ok | {:error, term()}
  def run(task_id) do
    case Snapshot.load(task_id) do
      :skip -> :ok
      {:ok, snap, repo} -> reconcile(snap, repo)
    end
  end

  defp reconcile(%{repository: %{available?: false}} = snap, repo) do
    {_actions, changes} = Decide.decide(snap, nil, now())
    finish(record(state(snap, repo, %{}), changes))
  end

  defp reconcile(snap, repo) do
    with {:ok, github} <- read_github(snap, repo) do
      {actions, changes} = Decide.decide(snap, github, now())
      {adopt, actions} = Enum.split_with(actions, &match?({:adopt, _}, &1))
      st = state(snap, repo, github)
      st = Enum.reduce(adopt, st, fn {:adopt, facts}, st -> adopt(st, facts) end)
      st = record(st, changes)

      st |> run_actions(actions) |> finish_with()
    end
  end

  defp finish_with({:ok, st}), do: finish(st)

  defp finish_with({:error, reason, st}) do
    :ok = finish(st)
    {:error, reason}
  end

  defp state(snap, repo, github),
    do: %{
      snap: snap,
      repo: repo,
      github: github,
      row: snap.pr,
      wrote?: false,
      poll: nil,
      stop?: false
    }

  defp finish(st) do
    if st.row, do: touch(st.row)
    if st.wrote?, do: PullRequests.wake(st.snap.task.id)
    if st.poll && not st.wrote?, do: PullRequests.poll(st.snap.task.id, st.poll)
    :ok
  end

  defp touch(row) do
    Repo.update_all(where(PullRequest, id: ^row.id), set: [reconciled_at: now()])
  end

  ## Step 2: GitHub

  defp read_github(snap, repo) do
    with {:ok, pr} <- read_pr(snap, repo),
         {:ok, found} <- find(snap, repo, pr),
         row = facts_row(snap.pr, pr),
         {:ok, checks} <- read_checks(snap, repo, row),
         {:ok, chain_base} <- read_chain(snap, repo, row),
         {:ok, included} <- read_included(snap, repo, row) do
      {:ok, %{pr: pr, found: found, checks: checks, chain_base: chain_base, included: included}}
    end
  end

  defp read_pr(%{pr: nil}, _repo), do: {:ok, nil}
  defp read_pr(%{pr: row}, repo), do: Api.get(repo, row.number)

  defp facts_row(nil, _facts), do: nil
  defp facts_row(row, nil), do: row
  defp facts_row(row, facts), do: %{row | state: facts.state, head_sha: facts.head_sha}

  # Decision 5 step 2: before any new pull request, an open one of the
  # task branch that is not recorded yet.
  defp find(snap, repo, facts) do
    open? = facts != nil and facts.state in [:draft, :open]
    merged_unrecorded? = facts != nil and facts.state == :merged and snap.pr.merged_at == nil

    if snap.latest_push == nil or open? or merged_unrecorded?,
      do: {:ok, nil},
      else: find_unrecorded(snap, repo)
  end

  @doc false
  # The open pull request of the task branch with the highest number that
  # has no row in the repository yet, or nil.
  @spec find_unrecorded(map(), map()) :: {:ok, Api.facts() | nil} | {:error, term()}
  def find_unrecorded(snap, repo) do
    with {:ok, prs} <- Api.find_open(repo, snap.branch, snap.project.base_branch) do
      numbers = Enum.map(prs, & &1.number)

      known =
        Repo.all(
          from(p in PullRequest,
            where: p.repository_id == ^snap.repository.id and p.number in ^numbers,
            select: p.number
          )
        )

      {:ok, prs |> Enum.reject(&(&1.number in known)) |> Enum.max_by(& &1.number, fn -> nil end)}
    end
  end

  defp read_checks(%{task: %{status: :verified}, verification: %{verified_sha: sha}}, repo, %{
         state: :open,
         head_sha: sha
       })
       when is_binary(sha),
       do: Api.checks(repo, sha)

  defp read_checks(_snap, _repo, _row), do: {:ok, nil}

  defp read_chain(
         %{task: %{status: :verified}, verification: %{verified_sha: sha}} = snap,
         repo,
         %{
           state: :open
         }
       )
       when is_binary(sha) do
    case Decide.chain_end(snap.pushes, sha) do
      {:ok, base} ->
        with {:ok, status} <- Api.compare(repo, snap.project.base_branch, base),
             do: {:ok, %{base => status}}

      {:broken, _sha} ->
        {:ok, %{}}
    end
  end

  defp read_chain(_snap, _repo, _row), do: {:ok, %{}}

  # Decision 21: is the latest push in the merged pull request? Only asked
  # when it is not its head and not recorded yet.
  defp read_included(
         %{latest_push: %{head_sha: latest}},
         repo,
         %PullRequest{state: :merged} = row
       )
       when latest != row.head_sha and latest != row.included_sha do
    case Api.compare(repo, latest, row.head_sha) do
      {:ok, status} when status in ["identical", "ahead"] -> {:ok, true}
      {:ok, _behind_diverged_or_not_found} -> {:ok, false}
      error -> error
    end
  end

  defp read_included(_snap, _repo, _row), do: {:ok, nil}

  ## Step 4: actions

  defp run_actions(st, actions) do
    Enum.reduce_while(actions, {:ok, st}, fn
      _action, {:ok, %{stop?: true}} = acc ->
        {:halt, acc}

      action, {:ok, st} ->
        case guarded(st, action) do
          {:ok, st} -> {:cont, {:ok, st}}
          {:error, reason} -> {:halt, {:error, reason, st}}
          {:error, reason, st} -> {:halt, {:error, reason, st}}
        end
    end)
  end

  # Every write (to GitHub or to the task) first checks, in a short
  # transaction, that what the decision was based on still holds:
  # otherwise the remaining actions are skipped and the task is woken
  # again (a fresh reconciliation decides).
  defp guarded(st, {:poll, seconds}), do: {:ok, %{st | poll: min_poll(st.poll, seconds)}}

  defp guarded(st, action) do
    if still_current?(st, action),
      do: action(st, action),
      else: {:ok, %{st | wrote?: true, stop?: true}}
  end

  defp action(st, {:create, params}), do: create(st, params, false)

  defp action(st, :close) do
    with {:ok, facts} <- Api.set_state(st.repo, st.row.number, "closed") do
      {:ok, st |> wrote() |> record([state: facts.state, closed_by_helmsman: true], facts: true)}
    end
  end

  defp action(st, :reopen) do
    with {:ok, facts} <- Api.set_state(st.repo, st.row.number, "open") do
      {:ok,
       st
       |> wrote()
       |> record([state: facts.state, head_sha: facts.head_sha, closed_by_helmsman: false],
         facts: true
       )}
    end
  end

  defp action(st, :to_draft) do
    case Api.set_draft(st.repo, st.row.node_id, true) do
      :ok ->
        {:ok, st |> wrote() |> record([state: :draft], facts: true)}

      {:error, {:graphql, message}} ->
        if message =~ ~r/draft/i,
          do: {:ok, record(st, [draft_supported: false], facts: true)},
          else: {:error, {:github_unavailable, {:graphql, message}}}

      error ->
        error
    end
  end

  defp action(st, :ready) do
    case Api.set_draft(st.repo, st.row.node_id, false) do
      :ok -> {:ok, st |> wrote() |> record([state: :open], facts: true)}
      {:error, {:graphql, message}} -> {:error, {:github_unavailable, {:graphql, message}}}
      error -> error
    end
  end

  defp action(st, {:merge, merge}), do: merge(st, merge)
  defp action(st, {:auto_reopen, attrs}), do: auto_reopen(st, attrs)
  defp action(st, {:escalate, attrs}), do: escalate(st, attrs)
  defp action(st, :cleanup), do: cleanup(st)

  defp min_poll(nil, seconds), do: seconds
  defp min_poll(current, seconds), do: min(current, seconds)

  defp wrote(st), do: %{st | wrote?: true}

  ## Opening a pull request (decision 6)

  defp create(st, params, restored?) do
    case Api.create(st.repo, params) do
      {:ok, facts} ->
        test_hook(:pull_request_created)

        {:ok,
         st
         |> wrote()
         |> insert_row(facts, draft_supported: Map.get(params, :draft_supported, true))}

      {:error, :draft_unsupported} when params.draft ->
        again(st, fn ->
          create(st, Map.merge(params, %{draft: false, draft_supported: false}), restored?)
        end)

      {:error, :already_exists} ->
        adopt_existing(st)

      {:error, :head_invalid} when not restored? ->
        restore_branch(st, params)

      {:error, :head_invalid} ->
        {:ok, branch_missing(st)}

      error ->
        error
    end
  end

  # "A pull request already exists": record it instead (decision 6).
  defp adopt_existing(st) do
    case find_unrecorded(st.snap, st.repo) do
      {:ok, nil} -> {:error, {:github_unavailable, :pull_request_not_found}}
      {:ok, facts} -> {:ok, st |> wrote() |> insert_row(facts, [])}
      error -> error
    end
  end

  # The task branch is gone (deleted after a merge): restore it at the
  # latest push, then create again once.
  defp restore_branch(st, params) do
    again(st, fn ->
      restored(st, params, Api.create_ref(st.repo, params.head, params.head_sha))
    end)
  end

  defp restored(st, params, :ok) do
    st = wrote(st)
    again(st, fn -> create(st, params, true) end)
  end

  defp restored(st, params, {:error, reason}) do
    Logger.info("task branch #{params.head} could not be restored: #{inspect(reason)}")
    {:ok, branch_missing(st)}
  end

  # A further write after an HTTP call within one action (a retry of the
  # creation, the branch restore) is checked like the action itself
  # (`guarded/2`).
  defp again(st, write) do
    if still_current?(st, :create),
      do: write.(),
      else: {:ok, %{st | wrote?: true, stop?: true}}
  end

  defp branch_missing(%{row: nil} = st), do: st
  defp branch_missing(st), do: record(st, Decide.branch_missing())

  # Test hooks: a crash between creating and recording a pull request, a
  # verification right before an automatic reopen.
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

  defp adopt(st, facts), do: insert_row(st, facts, [])

  defp insert_row(st, facts, extra) do
    %{snap: snap} = st

    {:ok, row} =
      Tx.run(fn ->
        lock(st)

        attrs = %PullRequest{
          workspace_id: snap.task.workspace_id,
          task_id: snap.task.id,
          repository_id: snap.repository.id,
          number: facts.number,
          node_id: facts.node_id,
          url: facts.url,
          branch: snap.branch,
          base_branch: facts.base_branch || snap.project.base_branch,
          state: facts.state,
          head_sha: facts.head_sha,
          draft_supported: Keyword.get(extra, :draft_supported, true)
        }

        row =
          case Repo.insert(attrs,
                 on_conflict: :nothing,
                 conflict_target: [:repository_id, :number]
               ) do
            {:ok, %PullRequest{id: nil}} ->
              Repo.get_by!(PullRequest, repository_id: snap.repository.id, number: facts.number)

            {:ok, row} ->
              notify(snap.task)
              row
          end

        {:ok, row}
      end)

    %{st | row: row}
  end

  ## Recording

  # Applies `changes` to the current row. Unless `facts: true`, what the
  # decision was based on is checked first (`current?/3`): when it moved
  # on, only the facts are recorded, the remaining actions are skipped and
  # the task is woken again. A merge recorded the first time wakes the
  # task too (an unrecorded open pull request may wait for adoption).
  defp record(st, changes, opts \\ [])
  defp record(%{row: nil} = st, _changes, _opts), do: st
  defp record(st, [], _opts), do: st

  defp record(st, changes, opts) do
    {:ok, {row, current?}} =
      Tx.run(fn ->
        {project, task} = lock(st)
        current? = Keyword.get(opts, :facts, false) or current?(st, project, task)
        changes = if current?, do: changes, else: Keyword.take(changes, @fact_keys)
        {:ok, {update_row(st.row, changes, st.snap.task), current?}}
      end)

    st = %{st | row: row}
    st = if Keyword.has_key?(changes, :merged_at), do: wrote(st), else: st
    if current?, do: st, else: %{st | stop?: true, wrote?: true}
  end

  # The decision still holds: the task's status and latest verification,
  # the project's binding and merge settings, and the row it is about is
  # still the current pull request of the bound repository (decision 20:
  # after a rebinding the old repository's pull request is left alone).
  defp current?(st, project, task) do
    snap = st.snap

    task.status == snap.task.status and
      latest_verification_id(task.id) == verification_id(snap) and
      Snapshot.settings(project) == snap.settings and
      (st.row == nil or current_row_id(task.id, project.repository_id) == st.row.id)
  end

  defp current_row_id(_task_id, nil), do: nil

  defp current_row_id(task_id, repository_id) do
    Repo.one(
      from(p in PullRequest,
        where: p.task_id == ^task_id and p.repository_id == ^repository_id,
        select: max(p.id)
      )
    )
  end

  # Before a write (`guarded/2`): `current?/3`, and for a merge (decision
  # 7 step 8) or the cleanup after it, no active run; for the cleanup also
  # the latest push still the merged head.
  defp still_current?(st, action) do
    {:ok, current?} =
      Tx.run(fn ->
        {project, task} = lock(st)
        {:ok, current?(st, project, task) and action_allowed?(st, action, task)}
      end)

    current?
  end

  defp action_allowed?(_st, {:merge, _merge}, task), do: not active_run?(task)

  defp action_allowed?(st, :cleanup, task),
    do: not active_run?(task) and latest_push_head(st, task) == st.row.head_sha

  defp action_allowed?(_st, _action, _task), do: true

  defp active_run?(task),
    do:
      Repo.exists?(
        from(r in Run, where: r.task_id == ^task.id and r.status in ^Run.active_statuses())
      )

  defp latest_push_head(st, task) do
    Repo.one(
      from(r in Run,
        where:
          r.task_id == ^task.id and r.repository_id == ^st.snap.repository.id and
            r.push_status == :pushed,
        order_by: [desc_nulls_last: r.claimed_at, desc: r.id],
        limit: 1,
        select: r.head_sha
      )
    )
  end

  defp verification_id(%{verification: nil}), do: nil
  defp verification_id(%{verification: %{id: id}}), do: id

  defp latest_verification_id(task_id) do
    Repo.one(
      from(e in TaskEvent,
        where: e.task_id == ^task_id and e.to_status == :verified,
        select: max(e.id)
      )
    )
  end

  # Lock order (designs/01 §4): maintenance lock (shared), project row,
  # task row, pull request row; the project and the task `FOR SHARE`.
  defp lock(%{snap: %{task: %{id: id, workspace_id: workspace_id, project_id: project_id}}}) do
    Locks.maint_shared!(workspace_id)
    project = Repo.one!(from(p in Project, where: p.id == ^project_id, lock: "FOR SHARE"))
    {project, Repo.one!(from(t in Task, where: t.id == ^id, lock: "FOR SHARE"))}
  end

  @doc false
  # Updates the locked pull request row (locks it `FOR UPDATE` first) and
  # registers `{:pull_request_changed, ident}` when a value changed. The
  # first `merged_at` and a new `included_sha` call the dependency hook
  # (`Helmsman.GitHub.PullRequests.after_merge/1`) in this transaction
  # (decision 21).
  @spec update_row(PullRequest.t(), keyword(), map()) :: PullRequest.t()
  def update_row(%PullRequest{id: id}, changes, task) do
    row = Repo.one!(from(p in PullRequest, where: p.id == ^id, lock: "FOR UPDATE"))
    changed = Enum.reject(changes, fn {key, value} -> Map.get(row, key) == value end)

    if changed == [] do
      row
    else
      row = row |> Ecto.Changeset.change(changed) |> Repo.update!()

      if Keyword.has_key?(changed, :merged_at) or Keyword.has_key?(changed, :included_sha),
        do: PullRequests.after_merge(row.task_id)

      notify(task)
      row
    end
  end

  defp notify(%{id: id, ident: ident}),
    do:
      Events.after_commit_once(
        {:pull_request_changed, id},
        Events.topic(:task, id),
        {:pull_request_changed, ident}
      )

  ## Merging (decision 7 steps 8, 9)

  # Checked before by `guarded/2` (step 8).
  defp merge(st, %{sha: sha, method: method}) do
    result =
      case Api.merge(st.repo, st.row.number, sha, method) do
        {:ok, merge_sha} -> {:ok, {:merged, merge_sha}}
        {:error, :head_changed} -> {:ok, :head_changed}
        {:error, {:not_allowed, message}} -> not_allowed(st, message)
        error -> error
      end

    with {:ok, outcome} <- result do
      {actions, changes} = Decide.merge_outcome(st.snap, st.row, st.snap.verification, outcome)
      st |> wrote() |> record(changes) |> run_actions(actions) |> unwrap()
    end
  end

  defp unwrap({:ok, st}), do: {:ok, st}
  defp unwrap({:error, reason, st}), do: {:error, reason, st}

  defp not_allowed(st, message) do
    with {:ok, facts} <- Api.get(st.repo, st.row.number),
         do: {:ok, {:not_allowed, facts.mergeable_state, message}}
  end

  ## Automatic reopens (decisions 8, 9)

  defp auto_reopen(st, attrs) do
    test_hook(:before_auto_reopen)

    result =
      Tx.run(fn ->
        with {:ok, _reopened} <- Tasks.auto_reopen(st.snap.task.id, attrs) do
          row = Repo.get!(PullRequest, st.row.id)

          row =
            update_row(
              row,
              [
                auto_reopen_count: row.auto_reopen_count + 1,
                merge_status: :none,
                merge_reason: nil,
                merge_note: reopen_note(attrs.reason),
                waiting_since: nil
              ],
              st.snap.task
            )

          {:ok, row}
        end
      end)

    case result do
      {:ok, row} -> {:ok, %{st | row: row, wrote?: true}}
      {:error, _stale} -> {:ok, %{st | wrote?: true, stop?: true}}
    end
  end

  defp reopen_note(:ci_failed), do: "CI failed; reopened for a fix."
  defp reopen_note(:merge_conflict), do: "Merge conflicts; reopened for a fix."

  defp escalate(st, %{verification_event_id: v_id, content: content}) do
    snap = st.snap

    {:ok, row} =
      Tx.run(fn ->
        Locks.maint_shared!(snap.task.workspace_id)
        task = Repo.one!(from(t in Task, where: t.id == ^snap.task.id, lock: "FOR UPDATE"))
        row = Repo.one!(from(p in PullRequest, where: p.id == ^st.row.id, lock: "FOR UPDATE"))

        if row.escalated_event_id != v_id and latest_verification_id(task.id) == v_id do
          {:ok, {_entry, task}} =
            Feedback.insert_locked(task, system_scope(task.workspace_id), %{
              kind: :question,
              content: content
            })

          Tasks.notify_summary(task)
          {:ok, update_row(row, [escalated_event_id: v_id], snap.task)}
        else
          {:ok, row}
        end
      end)

    {:ok, %{st | row: row}}
  end

  defp system_scope(workspace_id) do
    %Scope{
      workspace: Repo.get!(Workspace, workspace_id),
      actor:
        Repo.one!(from(a in Actor, where: a.workspace_id == ^workspace_id and a.kind == :system))
    }
  end

  ## Cleanup after the merge (decision 7, end)

  # Checked before by `guarded/2`, and again right before every DELETE
  # (the compares and ref reads in between are HTTP calls).
  defp cleanup(st) do
    case delete_task_branch(st) do
      {:ok, %{stop?: false} = st} -> delete_rescue_branches(st)
      other -> other
    end
  end

  defp delete_ref(st, branch) do
    if still_current?(st, :cleanup),
      do: Api.delete_branch(st.repo, branch),
      else: {:error, :stale}
  end

  defp delete_task_branch(%{row: %{branch_deleted_at: nil} = row} = st) do
    if st.snap.project.delete_branch_after_merge do
      with {:ok, head} <- Api.branch_head(st.repo, row.branch),
           do: delete_branch_at(st, row, head)
    else
      {:ok, st}
    end
  end

  defp delete_task_branch(st), do: {:ok, st}

  # Only when the branch still points to the merged head.
  defp delete_branch_at(st, _row, nil),
    do: {:ok, record(st, [branch_deleted_at: now()], facts: true)}

  defp delete_branch_at(st, %{head_sha: head} = row, head) do
    case delete_ref(st, row.branch) do
      :ok -> {:ok, st |> wrote() |> record([branch_deleted_at: now()], facts: true)}
      {:error, :stale} -> {:ok, %{st | wrote?: true, stop?: true}}
      error -> error
    end
  end

  defp delete_branch_at(st, _row, _moved), do: {:ok, st}

  defp delete_rescue_branches(%{row: %{rescue_cleaned_at: nil} = row} = st) do
    rescues = Enum.filter(st.snap.pushes, & &1.rescue_branch)

    result =
      Enum.reduce_while(rescues, {:ok, st}, fn push, {:ok, st} ->
        case delete_rescue(st, row, push) do
          {:ok, st} -> {:cont, {:ok, st}}
          {:error, :stale} -> {:halt, {:ok, %{st | wrote?: true, stop?: true}}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, %{stop?: false} = st} -> {:ok, record(st, [rescue_cleaned_at: now()], facts: true)}
      other -> other
    end
  end

  defp delete_rescue_branches(st), do: {:ok, st}

  # A rescue branch is deleted when its push is in the merged head and the
  # branch still points to it.
  defp delete_rescue(st, row, push) do
    with {:ok, status} <- Api.compare(st.repo, push.head_sha, row.head_sha),
         true <- status in ["identical", "ahead"],
         {:ok, head} <- Api.branch_head(st.repo, push.rescue_branch),
         true <- head == push.head_sha,
         :ok <- delete_ref(st, push.rescue_branch) do
      {:ok, wrote(st)}
    else
      false -> {:ok, st}
      {:error, _reason} = error -> error
    end
  end

  defp now, do: DateTime.utc_now()
end
