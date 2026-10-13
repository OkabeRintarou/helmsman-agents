defmodule Helmsman.LocalRepositories do
  @moduledoc """
  Local repository mode (`add-local-repositories`, designs/15 §8): the
  repositories daemons report from their machines, and the task branches
  delivered into them with their merge state.

  Registration (decision 4) runs inside `Helmsman.Daemons.register/3`
  (`register_locked/3`, `offline/2`); the daemon gets its repositories
  and the open branches to check in its `join` / `sync` reply
  (`reply_entries/1`) and reports merge checks with `repo_status`
  (`apply_status/2`). A local-mode push record is turned into the task's
  branch by `Workers.RecordBranch` (`record_branch/1`). People can mark a
  branch merged or not (`mark_merged/3`, `mark_unmerged/2`) and ask the
  daemon to check again (`refresh/2`).

  Lock order (designs/01 §4): maintenance lock → membership rows →
  daemon row → task row → `task_local_branches` row; local repository
  rows come after runtime rows.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Daemons.{Daemon, DaemonWorkspace, Locking}
  alias Helmsman.Dispatch.Dependencies
  alias Helmsman.Events
  alias Helmsman.LocalRepositories.{LocalRepository, TaskLocalBranch}
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.{Lifecycle, Run}
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.Tx
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.{Membership, Workspace}
  alias HelmsmanProtocol.Reply
  alias HelmsmanProtocol.Report.RepoStatus

  @max_watch 500
  @member_roles [:owner, :admin, :member]
  @max_note 2_000

  @not_configured "not configured on the machine"
  @not_shared "not shared with this workspace on the machine"
  @duplicate "duplicate name on the machine"

  ## Registration (decision 4)

  @doc """
  Inside `Helmsman.Daemons.register/3` (daemon row and membership rows
  locked): registers the `reported` repositories of daemon `daemon_id`
  in its valid workspaces `valid` — each only in the workspaces it is
  shared with on the machine. A repository of the daemon in a valid
  workspace that is no longer reported, or no longer shared with it,
  becomes `unavailable` with the reason; its project bindings stay.
  `nil` (protocol 1–2, or a daemon that does not report them) changes
  nothing. Returns the workspaces where a repository changed; each gets
  `{:local_repositories_changed}` after the commit.
  """
  @spec register_locked(
          pos_integer(),
          [pos_integer()],
          [HelmsmanProtocol.LocalRepository.t()] | nil
        ) ::
          [pos_integer()]
  def register_locked(_daemon_id, _valid, nil), do: []

  def register_locked(daemon_id, valid, reported) when is_list(reported) do
    before = states(daemon_id)
    time = now()
    reported = dedupe(reported)

    Repo.all(
      from(l in LocalRepository,
        where: l.daemon_id == ^daemon_id and l.workspace_id in ^valid,
        order_by: l.id,
        lock: "FOR UPDATE"
      )
    )
    |> Enum.each(&unreported(&1, reported, time))

    rows =
      for {name, repo} <- reported,
          workspace_id <- Enum.uniq(repo.workspaces),
          workspace_id in valid,
          do: row(daemon_id, workspace_id, name, repo, time)

    if rows != [] do
      Repo.insert_all(LocalRepository, rows,
        conflict_target: [:workspace_id, :daemon_id, :name],
        on_conflict:
          {:replace, [:path, :default_branch, :status, :unavailable_reason, :updated_at]}
      )
    end

    changed = changed_workspaces(before, states(daemon_id))
    Enum.each(changed, &notify_workspace/1)
    changed
  end

  # The first entry of a name wins; a name reported twice is unavailable.
  defp dedupe(reported) do
    reported
    |> Enum.group_by(& &1.name)
    |> Map.new(fn
      {name, [repo]} -> {name, repo}
      {name, [repo | _]} -> {name, %{repo | available: false, unavailable_reason: @duplicate}}
    end)
  end

  defp unreported(%LocalRepository{} = repo, reported, time) do
    reason =
      case Map.fetch(reported, repo.name) do
        :error -> @not_configured
        {:ok, entry} -> if repo.workspace_id in entry.workspaces, do: nil, else: @not_shared
      end

    if reason && (repo.status != "unavailable" or repo.unavailable_reason != reason) do
      Repo.update_all(from(l in LocalRepository, where: l.id == ^repo.id),
        set: [status: "unavailable", unavailable_reason: reason, updated_at: time]
      )
    end
  end

  defp row(daemon_id, workspace_id, name, repo, time) do
    %{
      workspace_id: workspace_id,
      daemon_id: daemon_id,
      name: name,
      path: repo.path,
      default_branch: repo.default_branch,
      status: if(repo.available, do: "online", else: "unavailable"),
      unavailable_reason: if(repo.available, do: nil, else: repo.unavailable_reason),
      inserted_at: time,
      updated_at: time
    }
  end

  @doc """
  Sets the `online` repositories of daemon `daemon_id` in `workspace_ids`
  `offline` (with its runtimes, `Helmsman.Daemons.offline/3`). Returns the
  workspaces where one changed; each gets `{:local_repositories_changed}`
  after the commit.
  """
  @spec offline(pos_integer(), [pos_integer()]) :: [pos_integer()]
  def offline(daemon_id, workspace_ids) do
    {_count, rows} =
      Repo.update_all(
        from(l in LocalRepository,
          where:
            l.daemon_id == ^daemon_id and l.workspace_id in ^workspace_ids and
              l.status == "online",
          select: l.workspace_id
        ),
        set: [status: "offline", updated_at: now()]
      )

    changed = Enum.uniq(rows)
    Enum.each(changed, &notify_workspace/1)
    changed
  end

  defp states(daemon_id) do
    Repo.all(
      from(l in LocalRepository,
        where: l.daemon_id == ^daemon_id,
        order_by: l.id,
        select: {l.workspace_id, l.id, l.path, l.default_branch, l.status, l.unavailable_reason}
      )
    )
    |> Enum.group_by(&elem(&1, 0))
  end

  defp changed_workspaces(before, after_states) do
    (Map.keys(before) ++ Map.keys(after_states))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(before, &1) != Map.get(after_states, &1)))
    |> Enum.sort()
  end

  defp notify_workspace(workspace_id),
    do:
      Events.after_commit_once(
        {:local_repositories_changed, workspace_id},
        Events.topic(:workspace, workspace_id),
        {:local_repositories_changed}
      )

  @doc """
  The daemon's repositories for its `join` / `sync` reply (protocol 3,
  decision 13): one entry per repository in each workspace it serves and
  where its user is a member or above, with the open task branches to
  check (`watch`, at most #{@max_watch}, most recently changed first; the
  base branch is the project's, else the repository's default branch).
  """
  @spec reply_entries(pos_integer()) :: [Reply.Join.LocalRepository.t()]
  def reply_entries(daemon_id) do
    Repo.all(
      from(l in LocalRepository,
        join: d in Daemon,
        on: d.id == l.daemon_id,
        join: dw in DaemonWorkspace,
        on: dw.daemon_id == l.daemon_id and dw.workspace_id == l.workspace_id,
        join: m in Membership,
        on: m.workspace_id == l.workspace_id and m.user_id == d.user_id,
        where: l.daemon_id == ^daemon_id and is_nil(l.removed_at) and m.role in ^@member_roles,
        order_by: [l.workspace_id, l.name]
      )
    )
    |> Enum.map(fn repo ->
      %Reply.Join.LocalRepository{
        workspace_id: repo.workspace_id,
        name: repo.name,
        local_repository_id: repo.id,
        watch: watch(repo)
      }
    end)
  end

  defp watch(repo) do
    Repo.all(
      from(b in TaskLocalBranch,
        join: t in Task,
        on: t.id == b.task_id,
        join: p in Project,
        on: p.id == t.project_id,
        where:
          b.local_repository_id == ^repo.id and b.state == "open" and
            not is_nil(coalesce(p.base_branch, ^repo.default_branch)),
        order_by: [desc: b.updated_at, desc: b.id],
        limit: @max_watch,
        select: %Reply.Join.Watch{
          branch: b.branch,
          head_sha: b.head_sha,
          base_branch: coalesce(p.base_branch, ^repo.default_branch)
        }
      )
    )
  end

  ## Reading (decision 4: visibility)

  @doc """
  The workspace's local repositories (`:read_tasks`), not removed, by
  machine and name: `%{id, name, daemon_id, daemon_name, owner: %{user_id,
  name}, status, unavailable_reason, default_branch, path}`. `path` is nil
  unless the reader owns the daemon or is a workspace owner / admin.
  """
  @spec list(Scope.t()) :: {:ok, [map()]} | {:error, :forbidden}
  def list(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    with :ok <- Policy.authorize(scope, :read_tasks) do
      {:ok,
       from(l in LocalRepository,
         where: l.workspace_id == ^workspace_id and is_nil(l.removed_at),
         order_by: [l.daemon_id, l.name]
       )
       |> Repo.all()
       |> to_views(scope)}
    end
  end

  @doc "Like `list/1` for the given repository IDs of the scope's workspace (no authorization)."
  @spec views_by_id([pos_integer()], Scope.t()) :: %{pos_integer() => map()}
  def views_by_id(ids, %Scope{workspace: %Workspace{id: workspace_id}} = scope)
      when is_list(ids) do
    from(l in LocalRepository, where: l.workspace_id == ^workspace_id and l.id in ^ids)
    |> Repo.all()
    |> to_views(scope)
    |> Map.new(&{&1.id, &1})
  end

  defp to_views([], _scope), do: []

  defp to_views(repos, scope) do
    daemons =
      Repo.all(
        from(d in Daemon,
          join: u in User,
          on: u.id == d.user_id,
          where: d.id in ^Enum.map(repos, & &1.daemon_id),
          select: {d.id, {d.name, u.id, coalesce(u.display_name, u.email)}}
        )
      )
      |> Map.new()

    Enum.map(repos, fn repo ->
      {daemon_name, user_id, user_name} = Map.fetch!(daemons, repo.daemon_id)

      %{
        id: repo.id,
        name: repo.name,
        daemon_id: repo.daemon_id,
        daemon_name: daemon_name,
        owner: %{user_id: user_id, name: user_name},
        status: repo.status,
        unavailable_reason: repo.unavailable_reason,
        default_branch: repo.default_branch,
        removed: not is_nil(repo.removed_at),
        path: if(path_visible?(scope, user_id), do: repo.path, else: nil)
      }
    end)
  end

  # Runs and agents first: their scopes keep the user they act for, who may
  # be the machine's owner.
  defp path_visible?(%Scope{via: :run}, _owner_id), do: false
  defp path_visible?(%Scope{actor: %Actor{kind: :agent}}, _owner_id), do: false
  defp path_visible?(%Scope{user: %User{id: id}}, id), do: true
  defp path_visible?(%Scope{role: role}, _owner_id), do: role in [:owner, :admin]

  @doc """
  The local branch of task `ident` (`:read_tasks`): `%{branch, head_sha,
  state, merged_at, merged_by, merge_note, base_branch, updated_at,
  local_repository}` or nil when the task has none; `local_repository` as
  in `list/1`, `base_branch` the branch merges are checked against (the
  project's, else the repository's default branch, as in the `watch` of
  `reply_entries/1`; nil when neither is known) and `updated_at` when the
  row last changed (a delivery or a merge state change).
  """
  @spec get_branch(Scope.t(), String.t()) ::
          {:ok, map() | nil} | {:error, :forbidden | :not_found}
  def get_branch(%Scope{workspace: %Workspace{id: workspace_id}} = scope, ident)
      when is_binary(ident) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, task} <- fetch_task(workspace_id, ident) do
      case Repo.get_by(TaskLocalBranch, task_id: task.id) do
        nil -> {:ok, nil}
        branch -> {:ok, branch_view(branch, task, scope)}
      end
    end
  end

  defp branch_view(branch, task, scope) do
    merged_by = branch.merged_by_id && Repo.get(Actor, branch.merged_by_id)
    repo = Map.get(views_by_id([branch.local_repository_id], scope), branch.local_repository_id)

    project_branch =
      Repo.one!(from(p in Project, where: p.id == ^task.project_id, select: p.base_branch))

    %{
      branch: branch.branch,
      head_sha: branch.head_sha,
      state: branch.state,
      merged_at: branch.merged_at,
      merged_by: merged_by && %{name: merged_by.name, kind: merged_by.kind},
      merge_note: branch.merge_note,
      base_branch: project_branch || (repo && repo.default_branch),
      updated_at: branch.updated_at,
      local_repository: repo
    }
  end

  defp fetch_task(workspace_id, ident) do
    with {:ok, ident, _key, _seq} <- Ident.parse(ident),
         %Task{} = task <-
           Repo.one(from(t in Task, where: t.workspace_id == ^workspace_id and t.ident == ^ident)) do
      {:ok, task}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The local repository `id` of `workspace_id` when it can be bound
  (exists, not removed), locked `FOR SHARE` (`Helmsman.Projects`).
  """
  @spec lock_bindable(pos_integer(), pos_integer()) ::
          {:ok, LocalRepository.t()} | {:error, :not_found}
  def lock_bindable(workspace_id, id) do
    query =
      from(l in LocalRepository,
        where: l.workspace_id == ^workspace_id and l.id == ^id and is_nil(l.removed_at),
        lock: "FOR SHARE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      repo -> {:ok, repo}
    end
  end

  ## Merge state (decision 9)

  @doc """
  Records the task branch for the local-mode push of run `run_id`
  (`Workers.RecordBranch`): maintenance lock, task row `FOR UPDATE`, then
  the branch row. The latest delivery is the push to the task branch
  (`push_status = pushed`; rescue branches never count) of the task's
  run on that repository with the greatest `(claimed_at, id)`; when its
  `head_sha` differs from the row's, the row takes it and goes back to
  `open`. A run whose repository is no longer the project's is skipped.
  After a change the task topic gets `{:local_branch_changed, ident}` and
  the repository's daemon `config_changed` (so its next `sync` reply
  watches the new commit).
  """
  @spec record_branch(pos_integer()) :: {:ok, :recorded | :unchanged | :skipped}
  def record_branch(run_id) do
    case Repo.get(Run, run_id) do
      %Run{local_repository_id: repo_id, task_id: task_id} = run
      when not is_nil(repo_id) and not is_nil(task_id) ->
        Tx.run(fn -> record_locked(run) end)

      _other ->
        {:ok, :skipped}
    end
  end

  defp record_locked(run) do
    Locks.maint_shared!(run.workspace_id)
    task = Repo.one!(from(t in Task, where: t.id == ^run.task_id, lock: "FOR UPDATE"))
    project = Repo.get!(Project, task.project_id)

    with true <- project.local_repository_id == run.local_repository_id,
         %Run{} = latest <- latest_delivery(task.id, run.local_repository_id) do
      upsert_branch(task, latest, lock_branch(task.id))
    else
      _skip -> {:ok, :skipped}
    end
  end

  defp latest_delivery(task_id, repo_id) do
    Repo.one(
      from(r in Run,
        where:
          r.task_id == ^task_id and r.local_repository_id == ^repo_id and
            r.push_status == :pushed,
        order_by: [desc: r.claimed_at, desc: r.id],
        limit: 1
      )
    )
  end

  defp lock_branch(task_id),
    do: Repo.one(from(b in TaskLocalBranch, where: b.task_id == ^task_id, lock: "FOR UPDATE"))

  defp upsert_branch(_task, latest, %TaskLocalBranch{} = branch)
       when branch.head_sha == latest.head_sha and branch.branch == latest.branch and
              branch.local_repository_id == latest.local_repository_id,
       do: {:ok, :unchanged}

  defp upsert_branch(task, latest, existing) do
    attrs = [
      local_repository_id: latest.local_repository_id,
      branch: latest.branch,
      head_sha: latest.head_sha,
      state: "open",
      merged_at: nil,
      merged_by_id: nil,
      merge_note: nil
    ]

    case existing do
      nil ->
        Repo.insert!(
          struct(TaskLocalBranch, [workspace_id: task.workspace_id, task_id: task.id] ++ attrs)
        )

      branch ->
        branch |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end

    notify_branch(task)
    config_changed(latest.local_repository_id)
    {:ok, :recorded}
  end

  @doc """
  A `repo_status` report (decision 13): the daemon row `FOR SHARE` in the
  connection's authorization epoch (else `{:error, :reauthorized}`), the
  daemon still serving the workspace with its owner a member or above and
  its repository `(workspace_id, daemon, name)` (else
  `{:error, :not_found}`), then one short transaction per result that is
  `merged: yes`, which checks the epoch and the service again: the branch
  becomes `merged` only while it is `open` with the same branch and
  `head_sha` (a result about an older delivery is ignored). The first
  failing check stops the report and is returned.
  """
  @spec apply_status(Lifecycle.daemon_ctx(), RepoStatus.t()) ::
          :ok | {:error, :reauthorized | :not_found}
  def apply_status(ctx, %RepoStatus{} = report) do
    with {:ok, repo} <- Tx.run(fn -> reporting_repository(ctx, report) end) do
      Locking.hook(:repo_status_checked)

      report.results
      |> Enum.filter(&(&1.merged == :yes))
      |> Enum.flat_map(fn item -> Enum.map(open_task_ids(repo.id, item), &{&1, item}) end)
      |> Enum.reduce_while(:ok, fn {task_id, item}, :ok ->
        ctx |> detected_merged(repo, task_id, item) |> continue_status()
      end)
    end
  end

  defp continue_status({:ok, _result}), do: {:cont, :ok}
  defp continue_status({:error, _reason} = error), do: {:halt, error}

  defp reporting_repository(ctx, report) do
    with {:ok, daemon} <- lock_serving(ctx, report.workspace_id) do
      LocalRepository
      |> Repo.get_by(workspace_id: report.workspace_id, daemon_id: daemon.id, name: report.name)
      |> found()
    end
  end

  # Maintenance lock, the machine owner's membership `FOR SHARE`, then the
  # daemon row `FOR SHARE` in the connection's epoch; the daemon must still
  # serve `workspace_id` with its owner a member or above. Revoking the
  # service (`Helmsman.Daemons.set_workspaces/3`, daemon row `FOR UPDATE`)
  # or the membership (membership row `FOR UPDATE`) is thus ordered with
  # each write: committed first, it makes the report `:not_found`.
  defp lock_serving(ctx, workspace_id) do
    Locks.maint_shared!(workspace_id)

    member? =
      Repo.exists?(
        from(m in Membership,
          join: d in Daemon,
          on: d.user_id == m.user_id,
          where:
            d.id == ^ctx.daemon_id and m.workspace_id == ^workspace_id and
              m.role in ^@member_roles,
          lock: fragment("FOR SHARE OF ?", m)
        )
      )

    with {:ok, daemon} <- Lifecycle.lock_daemon(ctx) do
      serves? =
        Repo.exists?(
          from(w in DaemonWorkspace,
            where: w.daemon_id == ^daemon.id and w.workspace_id == ^workspace_id
          )
        )

      if member? and serves?, do: {:ok, daemon}, else: {:error, :not_found}
    end
  end

  defp found(nil), do: {:error, :not_found}
  defp found(value), do: {:ok, value}

  defp open_task_ids(repo_id, item) do
    Repo.all(
      from(b in TaskLocalBranch,
        where:
          b.local_repository_id == ^repo_id and b.branch == ^item.branch and
            b.head_sha == ^item.head_sha and b.state == "open",
        select: b.task_id
      )
    )
  end

  defp detected_merged(ctx, repo, task_id, item) do
    Tx.run(fn ->
      with {:ok, _daemon} <- lock_serving(ctx, repo.workspace_id) do
        task = Repo.one!(from(t in Task, where: t.id == ^task_id, lock: "FOR UPDATE"))
        detected_locked(task, lock_branch(task_id), repo, item)
      end
    end)
  end

  defp detected_locked(task, %TaskLocalBranch{state: "open"} = branch, repo, item)
       when branch.local_repository_id == repo.id and branch.branch == item.branch and
              branch.head_sha == item.head_sha do
    branch |> Ecto.Changeset.change(state: "merged", merged_at: now()) |> Repo.update!()
    merged!(task)
    {:ok, :merged}
  end

  defp detected_locked(_task, _branch, _repo, _item), do: {:ok, :ignored}

  @doc """
  Marks the local branch of task `ident` merged, with an optional `note`
  (at most #{@max_note} characters), for merges the daemon cannot detect
  (squash, rebase, cherry-pick). People only (an agent: `:forbidden`),
  with the right to move tasks (`:transition_task`). The branch must be
  `open` (`{:error, {:invalid_state, state}}`); no branch: `:not_found`.

  With `expected_head_sha: sha` in `opts` (the commit the person saw),
  the branch's `head_sha` is compared under its row lock: a later
  delivery gives `{:error, {:head_changed, current_sha}}` and nothing is
  written.
  """
  @spec mark_merged(Scope.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def mark_merged(scope, ident, note \\ nil, opts \\ [])

  def mark_merged(%Scope{} = scope, ident, note, opts) when is_binary(ident) and is_list(opts) do
    expected = Keyword.get(opts, :expected_head_sha)

    with :ok <- person(scope),
         {:ok, note} <- normalize_note(note) do
      branch_write(scope, ident, &mark_expected_locked(&1, &2, scope.actor, note, expected))
    end
  end

  defp mark_expected_locked(task, branch, actor, note, expected) do
    with :ok <- expected_head(branch, expected),
         do: mark_merged_locked(task, branch, actor, note)
  end

  defp expected_head(_branch, nil), do: :ok
  defp expected_head(%TaskLocalBranch{head_sha: sha}, sha), do: :ok

  defp expected_head(%TaskLocalBranch{head_sha: sha}, _expected),
    do: {:error, {:head_changed, sha}}

  @doc """
  Clears the merged mark of the local branch of task `ident` (people
  only, `:transition_task`): the branch must be `merged`
  (`{:error, {:invalid_state, state}}`).

  `opts[:manual_only]` (default false): also require, under the branch
  row lock, that a person marked it (`merged_by_id` set); a merge found
  by the daemon's detection gives `{:error, :not_manual}` and nothing is
  written (`add-local-repositories-ui` D8: an in-flight undo must not
  clear a detected merge).
  """
  @spec mark_unmerged(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def mark_unmerged(%Scope{} = scope, ident, opts \\ []) when is_binary(ident) do
    manual_only? = Keyword.get(opts, :manual_only, false)

    with :ok <- person(scope) do
      branch_write(scope, ident, &mark_unmerged_locked(&1, &2, manual_only?))
    end
  end

  defp mark_merged_locked(task, %TaskLocalBranch{state: "open"} = branch, actor, note) do
    branch
    |> Ecto.Changeset.change(
      state: "merged",
      merged_at: now(),
      merged_by_id: actor.id,
      merge_note: note
    )
    |> Repo.update!()

    merged!(task)
    :ok
  end

  defp mark_merged_locked(_task, branch, _actor, _note),
    do: {:error, {:invalid_state, branch.state}}

  defp mark_unmerged_locked(_task, %TaskLocalBranch{state: "merged", merged_by_id: nil}, true),
    do: {:error, :not_manual}

  defp mark_unmerged_locked(task, %TaskLocalBranch{state: "merged"} = branch, _manual_only?) do
    branch
    |> Ecto.Changeset.change(state: "open", merged_at: nil, merged_by_id: nil, merge_note: nil)
    |> Repo.update!()

    notify_branch(task)
    Dependencies.changed(task.id)
  end

  defp mark_unmerged_locked(_task, branch, _manual_only?),
    do: {:error, {:invalid_state, branch.state}}

  @doc """
  Asks the daemon of the local repository of task `ident` to check merge
  states again now (`:transition_task`): it gets `config_changed`, sends
  `sync` and checks the branches of its reply. No branch: `:not_found`.
  """
  @spec refresh(Scope.t(), String.t()) :: :ok | {:error, :forbidden | :not_found}
  def refresh(%Scope{workspace: %Workspace{id: workspace_id}} = scope, ident)
      when is_binary(ident) do
    with :ok <- Policy.authorize(scope, :transition_task),
         {:ok, task} <- fetch_task(workspace_id, ident),
         %TaskLocalBranch{} = branch <- Repo.get_by(TaskLocalBranch, task_id: task.id) do
      Tx.run(fn ->
        config_changed(branch.local_repository_id)
        {:ok, :ok}
      end)

      :ok
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp person(%Scope{actor: %Actor{kind: :human}, via: via}) when via != :run, do: :ok
  defp person(%Scope{actor: nil}), do: {:error, :no_actor}
  defp person(_scope), do: {:error, :forbidden}

  defp normalize_note(nil), do: {:ok, nil}

  defp normalize_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> {:ok, nil}
      note -> if String.length(note) <= @max_note, do: {:ok, note}, else: {:error, :note_too_long}
    end
  end

  defp normalize_note(_note), do: {:error, :note_too_long}

  # Maintenance lock and membership row (write_transaction), task row,
  # branch row.
  defp branch_write(scope, ident, fun) do
    Workspaces.write_transaction(scope, :transition_task, fn scope ->
      with {:ok, ident, _key, _seq} <- Ident.parse(ident),
           %Task{} = task <-
             Repo.one(
               from(t in Task,
                 where: t.workspace_id == ^scope.workspace.id and t.ident == ^ident,
                 lock: "FOR UPDATE"
               )
             ),
           %TaskLocalBranch{} = branch <- lock_branch(task.id),
           :ok <- fun.(task, branch) do
        {:ok, branch_view(Repo.reload!(branch), task, scope)}
      else
        {:error, _reason} = error -> error
        _missing -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Whether the local branch of `task_id` is merged (designs/07 §3 for
  #31 / #32): `nil` when the task has no local branch (nothing was
  delivered), else `true` / `false`.
  """
  @spec merged?(pos_integer()) :: boolean() | nil
  def merged?(task_id) do
    case Repo.one(from(b in TaskLocalBranch, where: b.task_id == ^task_id, select: b.state)) do
      nil -> nil
      state -> state == "merged"
    end
  end

  @doc """
  Called once after a task's local branch became `merged` committed
  (decision 9). Notifies the task topic and emits the
  `[:helmsman, :local_repositories, :after_merge]` telemetry event
  (`%{task_id: id}`). The re-check of the tasks depending on it
  (`add-dependency-dispatch`) was registered in the transaction.
  """
  @spec after_merge(Task.t()) :: :ok
  def after_merge(%Task{} = task) do
    Events.broadcast(Events.topic(:task, task.id), {:local_branch_changed, task.ident})
    :telemetry.execute([:helmsman, :local_repositories, :after_merge], %{}, %{task_id: task.id})
  end

  # The dependents are checked again in the transaction of the merge
  # (`add-dependency-dispatch` decision 6); the rest after the commit.
  defp merged!(task) do
    :ok = Dependencies.changed(task.id)
    Tx.after_commit(fn -> after_merge(task) end)
  end

  defp notify_branch(task),
    do: Events.after_commit(Events.topic(:task, task.id), {:local_branch_changed, task.ident})

  defp config_changed(repo_id) do
    case Repo.one(from(l in LocalRepository, where: l.id == ^repo_id, select: l.daemon_id)) do
      nil -> :ok
      daemon_id -> Events.after_commit(Events.topic(:daemon, daemon_id), {:daemon_config_changed})
    end
  end

  defp now, do: DateTime.utc_now(:second)
end
