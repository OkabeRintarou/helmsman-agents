defmodule Helmsman.Tasks do
  @moduledoc """
  Tasks (designs/04 §2): created and edited by members and above, read by
  every member.

  Task numbers are allocated by incrementing the project's `task_seq` under
  its row lock, in the same transaction as the insert: concurrent creations
  in one project queue up, and a rollback gives the number back, so IDs are
  gap-free and never reused.

  After the commit, every creation or edit broadcasts
  `{:task_created | :task_updated, summary}` on the project topic and
  `{:task_updated, ident}` on the task topic.

  Status changes go through `transition/4` only (designs/05): the rules
  live in `Helmsman.Tasks.StateMachine`, the evidence checks in
  `Helmsman.Tasks.Evidence`.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.BQL.Executor
  alias Helmsman.Dispatch
  alias Helmsman.Dispatch.{Continuation, Dependencies, Targets}
  alias Helmsman.Events
  alias Helmsman.Feedback
  alias Helmsman.Links
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Projects
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.{Run, TaskGrant}
  alias Helmsman.Search
  alias Helmsman.Squads
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Squads.Squad
  alias Helmsman.Tx

  alias Helmsman.Tasks.{
    Epics,
    Evidence,
    Ident,
    StateMachine,
    Task,
    TaskEvent,
    TransitionContext,
    TransitionSteps,
    VerifiedSha
  }

  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  @type error :: Changeset.t() | :forbidden | :not_found | :no_actor | atom()
  @type actor_ref :: %{name: String.t(), kind: String.t(), unclaimed: boolean()} | nil
  @type summary :: %{
          id: String.t(),
          project_key: String.t(),
          title: String.t(),
          status: String.t(),
          priority: String.t(),
          labels: [String.t()],
          created_by: actor_ref(),
          assignee: actor_ref(),
          lock_version: pos_integer(),
          kind: String.t(),
          epic: String.t() | nil,
          progress: Epics.progress() | nil,
          commits: [String.t()],
          feedback_count: non_neg_integer(),
          open_question: boolean(),
          blocked: boolean(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }
  @type event_view :: %{
          from: String.t() | nil,
          to: String.t(),
          actor: actor_ref(),
          comment: String.t() | nil,
          commits: [String.t()],
          tests: %{command: String.t(), passed: boolean(), summary: String.t()} | nil,
          auto: boolean(),
          feedback: String.t() | nil,
          verified_sha: String.t() | nil,
          at: DateTime.t()
        }

  @default_limit 50
  @max_limit 200

  ## Creating

  @doc """
  Creates a task in the project with `project_key` (`:create_task`).

  `attrs`: `title`, `description`, `priority`, `labels`, `assignee` (an
  identity name; `nil` or `""` for none), `kind` (`"task"`, the default,
  or `"epic"`; never changed later) and `epic` (the ID of an epic of the
  workspace, any case, any project; `nil` or `""` for none). The task
  starts as `new`, created by `scope.actor`, with a creation entry in its
  history.

  With `epic` the workspace graph lock is taken first and the epic is
  recomputed as `:step_added` after the insert
  (`Helmsman.Tasks.Epics.recompute/3`). An unknown epic, a task that is
  not an epic or an epic given for an epic is a changeset error on `epic`.

  `depends_on` is a list of task IDs (any case, any project of the
  workspace; `nil` or `[]` for none): the new task waits for them
  (`Helmsman.Links.add_dependencies/3`). The links are written before the
  task is dispatched, so a task assigned to a managed agent whose
  prerequisites are not satisfied yet gets a deferred run that starts when
  they are (designs/13 §2.4). Like `epic` it takes the workspace graph
  lock first. An unknown or malformed ID, or the new task's own epic (it
  would wait for itself) is a changeset error on `depends_on`; a run may
  depend its new task on any task of the workspace.

  Assigned to a managed agent, the task is dispatched in the same
  transaction (`Helmsman.Dispatch.on_assignee_change/4`) unless `start` is
  `false` (`true`, `false` or `nil`; anything else is a changeset error on
  `start`); the returned task carries the outcomes in `dispatch`.

  Returns `{:error, :not_found}` for an unknown project and
  `{:error, :project_archived}` for an archived one.
  """
  @spec create(Scope.t(), String.t(), map()) :: {:ok, Task.t()} | {:error, error()}
  def create(%Scope{actor: nil}, _project_key, _attrs), do: {:error, :no_actor}

  def create(%Scope{workspace: %Workspace{}} = scope, project_key, attrs)
      when is_binary(project_key) and is_map(attrs) do
    Workspaces.write_transaction(scope, :create_task, fn scope ->
      epic_input = fetch_epic(attrs)
      depends_on = fetch_depends_on(attrs)
      :ok = lock_graph_for_create(scope.workspace.id, epic_input, depends_on)
      assignee = lock_assignee(scope.workspace.id, attrs)
      test_hook(:assignee_locked)

      {start?, start_error} = fetch_start(attrs)

      changeset =
        %Task{workspace_id: scope.workspace.id, created_by_id: scope.actor.id}
        |> Task.changeset(attrs)
        |> put_kind(attrs)
        |> put_assignee(assignee)
        |> put_start_error(start_error)

      changeset =
        put_epic(
          changeset,
          resolve_epic(scope.workspace.id, epic_input, Changeset.get_field(changeset, :kind))
        )

      {prerequisites, changeset} = put_depends_on(changeset, scope.workspace.id, depends_on)

      with :ok <- not_busy(assignee),
           {:ok, project} <- fetch_project(scope, project_key),
           :ok <- validate(changeset),
           {:ok, seq} <- allocate_seq(project) do
        test_hook(:seq_allocated)
        insert_task(scope, changeset, project, seq, {start?, prerequisites})
      end
    end)
  end

  defp fetch_project(scope, key) do
    case Projects.fetch_by_key(scope.workspace.id, key) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp validate(%Changeset{valid?: true}), do: :ok
  defp validate(changeset), do: {:error, changeset}

  # Lock order: maintenance lock, membership row, project row, task row
  # (designs/01 §4).
  defp allocate_seq(%Project{} = project) do
    query =
      from(p in Project,
        where:
          p.id == ^project.id and p.workspace_id == ^project.workspace_id and
            is_nil(p.archived_at),
        select: p.task_seq,
        update: [inc: [task_seq: 1], set: [updated_at: ^DateTime.utc_now(:second)]]
      )

    case Repo.update_all(query, []) do
      {1, [seq]} -> {:ok, seq}
      {0, _} -> {:error, :project_archived}
    end
  end

  defp insert_task(scope, changeset, project, seq, {start?, prerequisites}) do
    ident = Ident.build(project.key, seq)

    changeset =
      changeset
      |> Changeset.change(project_id: project.id, seq: seq, ident: ident)
      |> put_search()

    with {:ok, task} <- Repo.insert(changeset) do
      Repo.insert!(%TaskEvent{
        workspace_id: task.workspace_id,
        task_id: task.id,
        from_status: nil,
        to_status: :new,
        actor_id: scope.actor.id,
        source_run_id: source_run_id(scope)
      })

      :ok = recompute_epics(scope, nil, task.epic_id)
      :ok = Links.add_dependencies(scope, task, prerequisites)

      requested_grant(scope, task)
      {task, dispatch} = dispatch(scope, task, nil, start?)
      task = preload_detail(task)
      notify(:task_created, task)
      {:ok, %{task | dispatch: dispatch}}
    end
  end

  # A managed agent creating a task in a run is its requester: the grant
  # `requested` continuation triggers inherit (`add-continuation-triggers`
  # decision 5). Never removed: the requester does not change. A run as a
  # squad leader records its squad: the callback runs as it (`add-squads`
  # decision 2).
  defp requested_grant(%Scope{via: :run, run: %Run{} = run, actor: %Actor{} = agent}, task) do
    Repo.insert!(%TaskGrant{
      workspace_id: task.workspace_id,
      task_id: task.id,
      agent_id: agent.id,
      squad_id: run.squad_id,
      kind: :requested,
      root_initiator_user_id: run.root_initiator_user_id,
      causal_agent_ids: run.causal_agent_ids,
      granted_by_id: agent.id,
      inserted_at: DateTime.utc_now()
    })
  end

  defp requested_grant(_scope, _task), do: :ok

  # Fault injection for the atomicity tests: compiled in the test
  # environment only.
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

  @doc "Queries all workspace tasks with BQL or a saved filter; returns summaries, total and order."
  @spec query(Scope.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(scope, input, opts \\ []) do
    Executor.query(scope, input, opts, fn tasks ->
      tasks |> put_derived() |> Enum.map(&summary/1)
    end)
  end

  ## Reading

  @doc """
  Gets a task by ID (any case) with its creator, assignee and history
  preloaded. Malformed IDs and IDs of other workspaces return
  `{:error, :not_found}`.
  """
  @spec get(Scope.t(), String.t()) :: {:ok, Task.t()} | {:error, :forbidden | :not_found}
  def get(%Scope{workspace: %Workspace{id: workspace_id}} = scope, ident) when is_binary(ident) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, ident, _key, _seq} <- Ident.parse(ident) do
      case Repo.one(from(t in Task, where: t.workspace_id == ^workspace_id and t.ident == ^ident)) do
        nil -> {:error, :not_found}
        task -> {:ok, preload_detail(task)}
      end
    end
  end

  @doc """
  The canonical IDs among `idents` (any case) of the tasks that exist in the
  scope's workspace, for turning references in Markdown into links.

  Malformed IDs are ignored. One query, none when no ID is well formed; an
  empty set for a scope that may not read tasks.
  """
  @spec existing_idents(Scope.t(), Enumerable.t()) :: MapSet.t(String.t())
  def existing_idents(%Scope{workspace: %Workspace{id: workspace_id}} = scope, idents) do
    canonical =
      idents
      |> Enum.flat_map(fn ident ->
        case Ident.parse(ident) do
          {:ok, canonical, _key, _seq} -> [canonical]
          {:error, :not_found} -> []
        end
      end)
      |> Enum.uniq()

    with :ok <- Policy.authorize(scope, :read_tasks),
         [_ | _] <- canonical do
      from(t in Task,
        where: t.workspace_id == ^workspace_id and t.ident in ^canonical,
        select: t.ident
      )
      |> Repo.all()
      |> MapSet.new()
    else
      _ -> MapSet.new()
    end
  end

  @doc """
  Lists the tasks of the project with `project_key`, most recently updated
  first.

  ## Options

    * `:status` - a status or a list of statuses
    * `:label` - only tasks with this label
    * `:assignee` - an identity name; `""` for unassigned tasks
    * `:kind` - `:task` or `:epic` (strings in any case too)
    * `:epic` - the ID of an epic (any case): only its steps; `""` for
      the tasks that belong to no epic
    * `:limit` - at most this many tasks (default 50, at most 200)
    * `:offset` - skip this many tasks (default 0)
    * `:before` - `{updated_at, id}` of the last task of the previous page:
      only the tasks after it in this order (keyset pagination; `:offset`
      is then ignored)
    * `:q` - only the tasks that match this text themselves (ID, labels,
      title, description) or by an active feedback record, as in
      `Helmsman.Search.search/3`; the order and the pages do not change.
      Blank is ignored; a text with nothing to search for (only stop
      words) matches nothing.

  Returns `{:error, :not_found}` for an unknown project,
  `{:error, {:invalid, :kind}}` for an unknown kind and
  `{:error, {:invalid_query, :too_long | :not_a_string}}` for a `:q` over
  200 characters or not a string.
  """
  @spec list(Scope.t(), String.t(), keyword()) ::
          {:ok, [Task.t()]}
          | {:error, :forbidden | :not_found | {:invalid, :kind} | Search.Query.error()}
  def list(%Scope{workspace: %Workspace{id: workspace_id}} = scope, project_key, opts \\ [])
      when is_binary(project_key) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, kind} <- kind_filter(opts[:kind]),
         {:ok, text} <- text_filter(opts[:q]),
         {:ok, project} <- fetch_project(scope, project_key) do
      list_matching(workspace_id, project, kind, text, opts)
    end
  end

  defp list_matching(_workspace_id, _project, _kind, :nothing, _opts), do: {:ok, []}

  defp list_matching(workspace_id, project, kind, text, opts) do
    tasks =
      from(t in Task,
        as: :task,
        where: t.workspace_id == ^workspace_id and t.project_id == ^project.id,
        order_by: [desc: t.updated_at, desc: t.id],
        limit: ^limit(opts[:limit]),
        preload: [:created_by, :assignee]
      )
      |> select_blocked()
      |> page(opts[:before], opts[:offset])
      |> filter_status(opts[:status])
      |> matching_filters(workspace_id, kind, text, opts)
      |> Repo.all()
      |> put_derived()

    {:ok, tasks}
  end

  defp matching_filters(query, workspace_id, kind, text, opts) do
    query
    |> filter_label(opts[:label])
    |> filter_assignee(workspace_id, opts[:assignee])
    |> filter_kind(kind)
    |> filter_epic(workspace_id, opts[:epic])
    |> filter_text(text)
  end

  @doc "Counts all six statuses under the list filters, ignoring status and paging. One query."
  @spec count_by_status(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def count_by_status(%Scope{workspace: %Workspace{id: workspace_id}} = scope, key, opts \\ []) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, kind} <- kind_filter(opts[:kind]),
         {:ok, text} <- text_filter(opts[:q]) do
      tasks =
        from(t in Task, as: :task, where: t.workspace_id == ^workspace_id)
        |> matching_filters(workspace_id, kind, text, opts)

      rows =
        from(p in Project,
          left_join: t in subquery(tasks),
          on: t.project_id == p.id,
          where: p.workspace_id == ^workspace_id and p.key == ^String.upcase(key),
          group_by: [p.id, t.status],
          select: {t.status, count(t.id)}
        )
        |> Repo.all()

      case rows do
        [] ->
          {:error, :not_found}

        _ ->
          zero = Map.new(Task.statuses(), &{Atom.to_string(&1), 0})

          {:ok,
           Enum.reduce(rows, zero, fn {status, count}, acc ->
             if status, do: Map.put(acc, Atom.to_string(status), count), else: acc
           end)}
      end
    end
  end

  # `nil` (no filter), `:nothing` or the tsquery text.
  defp text_filter(nil), do: {:ok, nil}

  defp text_filter(q) do
    case Search.Query.parse(q) do
      {:ok, :blank} -> {:ok, nil}
      {:ok, groups} -> {:ok, Search.Query.to_tsquery(groups) || :nothing}
      {:error, _reason} = error -> error
    end
  end

  defp filter_text(query, nil), do: query
  defp filter_text(query, :nothing), do: where(query, false)
  defp filter_text(query, tsquery), do: where(query, ^Search.task_matches(tsquery, :task))

  defp limit(n) when is_integer(n), do: n |> max(0) |> min(@max_limit)
  defp limit(_), do: @default_limit

  # `blocked` in the list's own query (an `EXISTS`, `Helmsman.Links`).
  defp select_blocked(query),
    do: select_merge(query, ^%{blocked: Links.unsatisfied_dependency(:task)})

  defp page(query, nil, n) when is_integer(n) and n > 0, do: offset(query, ^n)
  defp page(query, nil, _offset), do: query

  defp page(query, {%DateTime{} = updated_at, id}, _offset) when is_integer(id),
    do: where(query, [t], fragment("(?, ?) < (?, ?)", t.updated_at, t.id, ^updated_at, ^id))

  @doc """
  Lists the tasks of the scope's workspace, in every project, whose
  assignee is `scope.actor` (`:read_tasks`), most recently updated first,
  at most #{@max_limit}.

  ## Options

    * `:status` - a status or a list of statuses, read by
      `Helmsman.Tasks.StateMachine.normalize/1` (default `new` and
      `in_progress`)

  Returns `{:error, :no_identity}` without a current identity and
  `{:error, {:invalid_status, input, valid}}` for an unknown status.
  """
  @spec list_assigned(Scope.t(), keyword()) ::
          {:ok, [summary()]}
          | {:error, :forbidden | :no_identity | {:invalid_status, term(), [Task.status()]}}
  def list_assigned(%Scope{workspace: %Workspace{id: workspace_id}} = scope, opts \\ []) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         %Actor{id: actor_id} <- scope.actor || {:error, :no_identity},
         {:ok, statuses} <-
           StateMachine.normalize_all(opts[:status] || [:new, :in_progress]) do
      statuses = Enum.map(statuses, &Atom.to_string/1)

      tasks =
        from(t in Task,
          as: :task,
          where:
            t.workspace_id == ^workspace_id and t.assignee_id == ^actor_id and
              fragment("? = ANY(?)", t.status, ^statuses),
          order_by: [desc: t.updated_at, desc: t.id],
          limit: @max_limit,
          preload: [:created_by, :assignee]
        )
        |> select_blocked()
        |> Repo.all()
        |> put_derived()

      {:ok, Enum.map(tasks, &summary/1)}
    end
  end

  @doc """
  Lists the distinct labels of the tasks of the project with
  `project_key`, sorted (`:read_tasks`). Returns `{:error, :not_found}` for
  an unknown project.
  """
  @spec list_labels(Scope.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :forbidden | :not_found}
  def list_labels(%Scope{workspace: %Workspace{id: workspace_id}} = scope, project_key)
      when is_binary(project_key) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, project} <- fetch_project(scope, project_key) do
      %{rows: rows} =
        Repo.query!(
          "SELECT DISTINCT unnest(labels) AS label FROM tasks " <>
            "WHERE workspace_id = $1 AND project_id = $2 ORDER BY 1",
          [workspace_id, project.id]
        )

      {:ok, List.flatten(rows)}
    end
  end

  # Compared as text: an unknown status matches nothing instead of raising.
  defp filter_status(query, nil), do: query

  defp filter_status(query, statuses) do
    statuses = statuses |> List.wrap() |> Enum.map(&to_string/1)
    where(query, [t], fragment("? = ANY(?)", t.status, ^statuses))
  end

  defp filter_label(query, nil), do: query

  defp filter_label(query, label) when is_binary(label) do
    label = label |> String.trim() |> String.downcase()
    where(query, [t], fragment("? @> ?", t.labels, ^[label]))
  end

  defp filter_assignee(query, _workspace_id, nil), do: query
  defp filter_assignee(query, _workspace_id, ""), do: where(query, [t], is_nil(t.assignee_id))

  defp filter_assignee(query, workspace_id, name) when is_binary(name) do
    ids =
      from(a in Actor, where: a.workspace_id == ^workspace_id and a.name == ^name, select: a.id)

    where(query, [t], t.assignee_id in subquery(ids))
  end

  defp kind_filter(nil), do: {:ok, nil}

  defp kind_filter(kind) do
    case normalize_kind(kind) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, {:invalid, :kind}}
    end
  end

  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind), do: where(query, [t], t.kind == ^kind)

  defp filter_epic(query, _workspace_id, nil), do: query
  defp filter_epic(query, _workspace_id, ""), do: where(query, [t], is_nil(t.epic_id))

  # An unknown or malformed ID matches nothing.
  defp filter_epic(query, workspace_id, ident) when is_binary(ident) do
    case Ident.parse(String.trim(ident)) do
      {:ok, ident, _key, _seq} ->
        ids =
          from(e in Task,
            where: e.workspace_id == ^workspace_id and e.ident == ^ident,
            select: e.id
          )

        where(query, [t], t.epic_id in subquery(ids))

      {:error, :not_found} ->
        where(query, [t], false)
    end
  end

  ## Editing

  @doc """
  Edits a task's title, description, priority, labels, assignee and epic
  (`:update_task`); `status` and every other field in `attrs` are ignored.
  A `kind` equal to the current one is ignored too; a different one is a
  changeset error on `kind` (it is never changed).

  With a `lock_version` that is not the current one the result is
  `{:error, :stale}`, checked before anything else. Without one the edit
  applies to the latest version (last write wins). An edit that changes
  something bumps `lock_version` and notifies; one that changes nothing
  returns the task as it is.

  A run scope may only edit its own task (`:write_task`). A new assignee
  is dispatched as in `create/3` (`start` included, which is not a field:
  an edit that only gives `start` changes nothing).

  With an `assignee` key the workspace graph lock is taken before the
  assignee's rows (`add-dependency-dispatch` decision 4).

  `epic` is read as in `create/3` (`""` detaches the task). With an `epic`
  key the workspace graph lock is taken before the task row; after the
  version check the old and the new epic rows are locked `FOR UPDATE` in
  ascending ID order. A change of epic bumps the task's `lock_version`
  and recomputes the old epic as `:step_removed` and the new one as
  `:step_added`; the epics' `lock_version` does not change. Without an
  `epic` or `assignee` key no graph lock is taken.
  """
  @spec update(Scope.t(), String.t(), map(), pos_integer() | nil) ::
          {:ok, Task.t()} | {:error, error()}
  def update(scope, ident, attrs, lock_version \\ nil)

  def update(%Scope{actor: nil}, _ident, _attrs, _lock_version), do: {:error, :no_actor}

  def update(%Scope{workspace: %Workspace{}} = scope, ident, attrs, lock_version)
      when is_binary(ident) and is_map(attrs) and
             (is_nil(lock_version) or is_integer(lock_version)) do
    Workspaces.write_transaction(scope, :update_task, fn scope ->
      with {:ok, ident, _key, _seq} <- Ident.parse(ident),
           epic_input = fetch_epic(attrs),
           :ok <- lock_graph_for_update(scope.workspace.id, epic_input, attrs),
           assignee = lock_assignee(scope.workspace.id, attrs),
           _ = test_hook(:assignee_locked),
           :ok <- not_busy(assignee),
           {:ok, task} <- lock_task(scope.workspace.id, ident),
           :ok <- Policy.authorize(scope, :write_task, task),
           :ok <- check_version(task, lock_version) do
        test_hook(:version_checked)
        epic = lock_epics(task, epic_input)
        {start?, start_error} = fetch_start(attrs)

        task
        |> Task.changeset(attrs)
        |> check_kind_unchanged(attrs)
        |> put_assignee(assignee)
        |> put_start_error(start_error)
        |> put_epic(epic)
        |> save(scope, start?)
      end
    end)
  end

  @doc """
  Locks the task `ident` (any case) of the scope's workspace `FOR UPDATE`
  inside the caller's write transaction, without authorization: for
  domain writes that act on a task (`Helmsman.Dispatch.run_agent/4`).
  """
  @spec lock(Scope.t(), String.t()) :: {:ok, Task.t()} | {:error, :not_found}
  def lock(%Scope{workspace: %Workspace{id: workspace_id}}, ident) when is_binary(ident) do
    with {:ok, ident, _key, _seq} <- Ident.parse(ident), do: lock_task(workspace_id, ident)
  end

  defp lock_task(workspace_id, ident) do
    query =
      from(t in Task,
        where: t.workspace_id == ^workspace_id and t.ident == ^ident,
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  defp check_version(_task, nil), do: :ok
  defp check_version(%Task{lock_version: version}, version), do: :ok
  defp check_version(_task, _version), do: {:error, :stale}

  defp save(%Changeset{valid?: false} = changeset, _scope, _start?), do: {:error, changeset}

  defp save(%Changeset{changes: changes} = changeset, _scope, _start?) when changes == %{},
    do: {:ok, preload_detail(changeset.data)}

  defp save(changeset, scope, start?) do
    prev_assignee_id = changeset.data.assignee_id

    changeset =
      changeset
      |> Changeset.change(lock_version: changeset.data.lock_version + 1)
      |> put_search_if_changed()

    with {:ok, task} <- Repo.update(changeset) do
      :ok = recompute_epics(scope, changeset.data.epic_id, task.epic_id)

      {task, dispatch} =
        if task.assignee_id != prev_assignee_id,
          do: dispatch(scope, task, prev_assignee_id, start?),
          else: {task, []}

      task = preload_detail(task)
      notify(:task_updated, task)
      {:ok, %{task | dispatch: dispatch}}
    end
  end

  # The search column, in the statement that writes the indexed fields
  # (`add-fulltext-search` decision 5).
  defp put_search(changeset) do
    Changeset.put_change(
      changeset,
      :search,
      Search.Document.task(%{
        ident: Changeset.get_field(changeset, :ident),
        labels: Changeset.get_field(changeset, :labels),
        title: Changeset.get_field(changeset, :title),
        description: Changeset.get_field(changeset, :description)
      })
    )
  end

  defp put_search_if_changed(%Changeset{changes: changes} = changeset) do
    if Enum.any?([:title, :description, :labels], &Map.has_key?(changes, &1)),
      do: put_search(changeset),
      else: changeset
  end

  # The task is read again after a dispatch: a refused trigger chain adds
  # a system comment to it.
  defp dispatch(_scope, %Task{assignee_id: nil} = task, nil, _start?), do: {task, []}

  defp dispatch(scope, task, prev_assignee_id, start?) do
    case Dispatch.on_assignee_change(scope, task, prev_assignee_id, start?) do
      {:ok, []} -> {task, []}
      {:ok, outcomes} -> {Repo.reload!(task), outcomes}
    end
  end

  # `start` is not a task field: `true`, `false` or `nil` (`true`).
  defp fetch_start(attrs) do
    case fetch_attr(attrs, :start) do
      {:ok, value} when is_boolean(value) -> {value, nil}
      {:ok, nil} -> {true, nil}
      :error -> {true, nil}
      {:ok, _other} -> {true, "is invalid"}
    end
  end

  defp put_start_error(changeset, nil), do: changeset
  defp put_start_error(changeset, message), do: Changeset.add_error(changeset, :start, message)

  defp source_run_id(%Scope{via: :run, run: %{id: id}}), do: id
  defp source_run_id(_scope), do: nil

  ## Kind and epic

  defp normalize_kind(kind) when kind in [:task, :epic], do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    case kind |> String.trim() |> String.downcase() do
      "task" -> {:ok, :task}
      "epic" -> {:ok, :epic}
      _other -> :error
    end
  end

  defp normalize_kind(_kind), do: :error

  defp put_kind(changeset, attrs) do
    case fetch_attr(attrs, :kind) do
      {:ok, kind} when not is_nil(kind) ->
        case normalize_kind(kind) do
          {:ok, kind} -> Changeset.put_change(changeset, :kind, kind)
          :error -> Changeset.add_error(changeset, :kind, "is invalid")
        end

      _absent ->
        changeset
    end
  end

  # Changing the kind is a clear intent: an error, not silently ignored as
  # `status` is.
  defp check_kind_unchanged(%Changeset{data: %Task{kind: current}} = changeset, attrs) do
    with {:ok, kind} when not is_nil(kind) <- fetch_attr(attrs, :kind),
         false <- normalize_kind(kind) == {:ok, current} do
      Changeset.add_error(changeset, :kind, "cannot be changed")
    else
      _same_or_absent -> changeset
    end
  end

  # `epic`: an epic's ID (any case); nil or "" for none; a missing key
  # keeps the current one.
  defp fetch_epic(attrs) do
    case fetch_attr(attrs, :epic) do
      :error -> :keep
      {:ok, nil} -> {:set, nil}
      {:ok, ident} when is_binary(ident) -> parse_epic(String.trim(ident))
      {:ok, _other} -> {:invalid, "is invalid"}
    end
  end

  defp parse_epic(""), do: {:set, nil}

  defp parse_epic(ident) do
    case Ident.parse(ident) do
      {:ok, ident, _key, _seq} -> {:ident, ident}
      {:error, :not_found} -> {:invalid, "not found"}
    end
  end

  # Taken whenever `epic` or `depends_on` is given, before anything is
  # known about a change: never after a task row lock (designs/01 §4).
  defp lock_graph_for_create(workspace_id, epic_input, depends_on) do
    if epic_input == :keep and depends_on == {:ok, []},
      do: :ok,
      else: Locks.graph!(workspace_id)
  end

  # `depends_on`: a list of task IDs (any case); nil or a missing key for
  # none. The IDs are deduplicated.
  defp fetch_depends_on(attrs) do
    case fetch_attr(attrs, :depends_on) do
      :error -> {:ok, []}
      {:ok, nil} -> {:ok, []}
      {:ok, ids} when is_list(ids) -> parse_depends_on(ids)
      {:ok, _other} -> {:invalid, "is invalid"}
    end
  end

  defp parse_depends_on(ids) do
    parsed = Enum.map(ids, &parse_depends_on_id/1)

    if :error in parsed,
      do: {:invalid, "has an invalid task ID"},
      else: {:ok, parsed |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}
  end

  defp parse_depends_on_id(id) when is_binary(id) do
    case Ident.parse(String.trim(id)) do
      {:ok, ident, _key, _seq} -> {:ok, ident}
      {:error, :not_found} -> :error
    end
  end

  defp parse_depends_on_id(_id), do: :error

  # Resolves the prerequisites of a new task, after its epic is known: the
  # tasks and the changeset (an error on `depends_on` when one is unknown
  # or the task's own epic). Tasks are never deleted and the graph lock is
  # held, so the rows need no lock of their own.
  defp put_depends_on(changeset, _workspace_id, {:ok, []}), do: {[], changeset}

  defp put_depends_on(changeset, _workspace_id, {:invalid, message}),
    do: {[], Changeset.add_error(changeset, :depends_on, message)}

  defp put_depends_on(changeset, workspace_id, {:ok, idents}) do
    found =
      from(t in Task, where: t.workspace_id == ^workspace_id and t.ident in ^idents)
      |> Repo.all()
      |> Map.new(&{&1.ident, &1})

    epic_id = Changeset.get_field(changeset, :epic_id)

    cond do
      missing = Enum.find(idents, &(not is_map_key(found, &1))) ->
        {[], Changeset.add_error(changeset, :depends_on, "#{missing} not found")}

      epic_id && Enum.any?(found, fn {_ident, task} -> task.id == epic_id end) ->
        {[], Changeset.add_error(changeset, :depends_on, "cannot include the task's own epic")}

      true ->
        {Enum.map(idents, &Map.fetch!(found, &1)), changeset}
    end
  end

  # An edit also takes it whenever `assignee` is given, before the
  # assignee's actor row: dispatching the new assignee reads the task's
  # dependencies under it (`add-dependency-dispatch` decision 4).
  defp lock_graph_for_update(workspace_id, epic_input, attrs) do
    if epic_input != :keep or fetch_attr(attrs, :assignee) != :error,
      do: Locks.graph!(workspace_id),
      else: :ok
  end

  # For a new task. A task's kind never changes and tasks are never
  # deleted, so the check needs no lock; `Epics.recompute/3` locks the
  # epic row after the insert.
  defp resolve_epic(_workspace_id, {:ident, _ident}, :epic),
    do: {:invalid, "an epic cannot belong to another epic"}

  defp resolve_epic(workspace_id, {:ident, ident}, _kind) do
    query =
      from(t in Task,
        where: t.workspace_id == ^workspace_id and t.ident == ^ident,
        select: {t.id, t.kind}
      )

    check_epic(Repo.one(query))
  end

  defp resolve_epic(_workspace_id, epic_input, _kind), do: epic_input

  # For an edit, after the version check: the old and the new epic rows
  # `FOR UPDATE`, in ascending ID order.
  defp lock_epics(%Task{kind: :epic}, {:ident, _ident}),
    do: {:invalid, "an epic cannot belong to another epic"}

  defp lock_epics(%Task{} = task, {:ident, ident}) do
    rows =
      from(t in Task,
        where:
          t.workspace_id == ^task.workspace_id and
            (t.ident == ^ident or t.id == ^(task.epic_id || 0)),
        order_by: t.id,
        lock: "FOR UPDATE",
        select: {t.id, t.kind, t.ident}
      )
      |> Repo.all()

    rows
    |> Enum.find_value(fn {id, kind, row_ident} -> row_ident == ident && {id, kind} end)
    |> check_epic()
  end

  defp lock_epics(%Task{epic_id: epic_id} = task, {:set, nil}) when is_integer(epic_id) do
    Repo.one!(
      from(t in Task,
        where: t.workspace_id == ^task.workspace_id and t.id == ^epic_id,
        lock: "FOR UPDATE",
        select: t.id
      )
    )

    {:set, nil}
  end

  defp lock_epics(_task, epic_input), do: epic_input

  defp check_epic(nil), do: {:invalid, "not found"}
  defp check_epic({id, :epic}), do: {:set, id}
  defp check_epic({_id, _kind}), do: {:invalid, "is not an epic"}

  defp put_epic(changeset, :keep), do: changeset
  defp put_epic(changeset, {:set, id}), do: Changeset.put_change(changeset, :epic_id, id)

  defp put_epic(changeset, {:invalid, message}),
    do: Changeset.add_error(changeset, :epic, message)

  defp recompute_epics(_scope, same, same), do: :ok

  # A step attached or detached may change whether its epic is satisfied:
  # the epics' dependents are checked again after the commit
  # (`add-dependency-dispatch` decision 6).
  defp recompute_epics(scope, old_epic_id, new_epic_id) do
    attrs = %{actor_id: scope.actor.id, source_run_id: source_run_id(scope)}
    if old_epic_id, do: :ok = Epics.recompute(old_epic_id, :step_removed, attrs)
    if new_epic_id, do: :ok = Epics.recompute(new_epic_id, :step_added, attrs)
    :ok = Dependencies.changed(old_epic_id)
    Dependencies.changed(new_epic_id)
  end

  ## Transitions

  @doc """
  Moves the task `ident` to the status `to` (`:transition_task`) and
  returns its detail (`detail/1`).

  `to` is read by `Helmsman.Tasks.StateMachine.normalize/1`; `opts` (a map
  or keyword list) may carry `comment`, `commits` and `tests`, checked by
  `Helmsman.Tasks.Evidence.normalize/1`, and `feedback`, a reason
  `%{kind, content}` checked by `Helmsman.Feedback.normalize/1`, and
  `expected_from`, the status the caller saw (read like `to`; nil or
  absent: not checked). All are checked before the transaction starts.

  With `expected_from`, the task's status is compared with it right after
  the task row is locked: when they differ the result is
  `{:error, {:status_changed, current}}` and nothing is written or
  broadcast.

  In one transaction, after the maintenance lock and the membership row:
  the workspace graph lock, the trigger targets and the task row
  `FOR UPDATE` (`Helmsman.Dispatch.Targets.with_locked/4`), the check context
  (`Helmsman.Tasks.TransitionContext`), `Helmsman.Tasks.StateMachine.check/3`,
  the reason feedback, if any (`Helmsman.Feedback.insert_locked/3`), the
  history entry (referring to the reason), the new status and the steps of
  `Helmsman.Tasks.TransitionSteps`, then the continuation and mention
  triggers (`Helmsman.Dispatch.Continuation`): the result carries their
  outcomes in `dispatch`, the transition's own first, then those of the
  reason (also kept on the reason). A failure at any step rolls the reason
  back with the rest. Concurrent transitions of a task run
  one after the other, each checked against the status the previous one
  committed.

  Moving a `new` task without an assignee to `in_progress` claims it: the
  acting identity becomes the assignee and `lock_version` grows by one.
  Other transitions leave both unchanged.

  After the commit `{:task_updated, summary}` is broadcast on the project
  topic and `{:task_transitioned, %{ident: ident, event: event}}` on the
  task topic, `event` being the new history entry (`event_view/1`), and,
  with a reason, `{:feedback_added, view}` on the task topic before it.

  Errors: `{:invalid_status, input, valid}`, `{:invalid_comment, _}`,
  `{:invalid_commits, bad}`, `{:invalid_tests, _}`, a changeset or
  `{:invalid_feedback, :not_an_object}` for the reason, `:forbidden`,
  `:not_found`, `:no_actor`, `{:status_changed, current}`, `:busy` (the
  trigger targets kept changing, `Helmsman.Dispatch.Targets`) and the reasons
  of `StateMachine.check/3`
  (`{:invalid_transition, from, to, allowed}`,
  `{:self_verify_requires_tests, assignee}`, ...).
  """
  @spec transition(Scope.t(), String.t(), term(), map() | keyword()) ::
          {:ok, map()} | {:error, error() | tuple()}
  def transition(scope, ident, to, opts \\ %{})

  def transition(%Scope{actor: nil}, _ident, _to, _opts), do: {:error, :no_actor}

  def transition(%Scope{workspace: %Workspace{}} = scope, ident, to, opts)
      when is_binary(ident) and (is_map(opts) or is_list(opts)) do
    with {:ok, to} <- StateMachine.normalize(to),
         {:ok, expected_from} <- normalize_expected_from(opts),
         {:ok, evidence} <- Evidence.normalize(opts),
         {:ok, reason} <- normalize_reason(opts) do
      Workspaces.write_transaction(scope, :transition_task, fn scope ->
        transition_locked(scope, ident, {expected_from, to}, evidence, reason)
      end)
    end
  end

  defp normalize_expected_from(opts) do
    case opts |> Map.new() |> fetch_attr(:expected_from) do
      {:ok, nil} -> {:ok, nil}
      {:ok, status} -> StateMachine.normalize(status)
      :error -> {:ok, nil}
    end
  end

  defp normalize_reason(opts) do
    case opts |> Map.new() |> fetch_attr(:feedback) do
      {:ok, reason} when is_map(reason) and not is_struct(reason) -> Feedback.normalize(reason)
      {:ok, nil} -> {:ok, nil}
      {:ok, _other} -> {:error, {:invalid_feedback, :not_an_object}}
      :error -> {:ok, nil}
    end
  end

  # Lock order: maintenance lock, membership row (write_transaction), graph
  # lock, trigger targets, task row (designs/01 §4,
  # `Helmsman.Dispatch.Targets`).
  defp transition_locked(scope, ident, {expected_from, to}, evidence, reason) do
    with {:ok, ident, _key, _seq} <- Ident.parse(ident),
         :ok <- Locks.graph!(scope.workspace.id),
         {:ok, task, plan} <- lock_targets(scope, ident, to, reason),
         :ok <- Policy.authorize(scope, :write_task, task),
         :ok <- check_expected_from(task, expected_from),
         ctx = TransitionContext.build(task, scope, to, evidence),
         :ok <- StateMachine.check(task.status, to, ctx) do
      {entry, task} = insert_reason(task, scope, reason, plan)
      test_hook(:reason_inserted)

      event =
        Repo.insert!(%TaskEvent{
          workspace_id: task.workspace_id,
          task_id: task.id,
          from_status: task.status,
          to_status: to,
          actor_id: scope.actor.id,
          comment: evidence.comment,
          commits: evidence.commits,
          tests: evidence.tests,
          auto: false,
          feedback_id: entry && entry.id,
          source_run_id: source_run_id(scope),
          verified_sha: if(to == :verified, do: VerifiedSha.compute(task)),
          # `add-squads` decision 11: who was on the assignee side.
          assignee_side_ids: if(to == :verified, do: Squads.assignee_side(task))
        })

      task = task |> Changeset.change(transition_changes(task, to, scope)) |> Repo.update!()
      finish_transition(scope, task, event, entry, plan)
    end
  end

  defp lock_targets(scope, ident, to, reason, opts \\ []) do
    workspace_id = scope.workspace.id

    Targets.with_locked(
      workspace_id,
      fn -> Continuation.guess(workspace_id, ident, reason && reason.content) end,
      fn -> lock_task(workspace_id, ident) end,
      &Continuation.plan_transition(scope, &1, to, reason, opts)
    )
  end

  # After the steps, the triggers (`add-continuation-triggers`): the
  # transition's own first, then those of its reason, whose outcomes are
  # written onto it before its notification.
  defp finish_transition(scope, task, event, entry, plan) do
    with :ok <- TransitionSteps.run(task, event, scope) do
      {own, by_reason} = Continuation.run_transition(scope, plan, task, entry)
      task = if entry, do: elem(Feedback.finish_locked(task, entry, by_reason), 1), else: task
      task = if own == [], do: task, else: Repo.reload!(task)
      task = preload_detail(task)
      event = Enum.find(task.events, &(&1.id == event.id))
      notify_transition(task, event)
      {:ok, task |> detail() |> Map.put(:dispatch, own ++ by_reason)}
    end
  end

  defp check_expected_from(_task, nil), do: :ok
  defp check_expected_from(%Task{status: status}, status), do: :ok

  defp check_expected_from(%Task{status: status}, _expected),
    do: {:error, {:status_changed, status}}

  defp insert_reason(task, _scope, nil, _plan), do: {nil, task}

  defp insert_reason(task, scope, reason, plan) do
    {:ok, {entry, task}} =
      Feedback.insert_locked(task, scope, reason, mentions: plan.feedback.mentions, notify: false)

    {entry, task}
  end

  # Claiming is the only transition that edits a field, so the only one
  # that bumps the version: a status change alone must not make concurrent
  # field edits stale.
  defp transition_changes(%Task{status: :new, assignee_id: nil} = task, :in_progress, scope),
    do: [status: :in_progress, assignee_id: scope.actor.id, lock_version: task.lock_version + 1]

  defp transition_changes(_task, to, _scope), do: [status: to]

  @doc """
  Moves the task of a run that just started to `in_progress`, as the
  run's agent (`add-run-lifecycle` decision 12): a server decision, not
  authorized by `Helmsman.Policy`. In its own transaction, in the order of
  transitions (maintenance lock, graph lock, task row `FOR UPDATE`); only
  while the task is `new` and its assignee is the agent, or the squad the
  run is a leader of (`add-squads` decision 7; the assignee stays). The
  history entry
  is `auto` and refers to the run; a unique index makes a second one for
  the same run impossible. The notifications are those of `transition/4`.
  Returns `{:ok, :claimed | :skipped}`.
  """
  @spec auto_claim_for_run(Helmsman.Runs.Run.t()) :: {:ok, :claimed | :skipped}
  def auto_claim_for_run(%Helmsman.Runs.Run{task_id: nil}), do: {:ok, :skipped}

  def auto_claim_for_run(%Helmsman.Runs.Run{} = run) do
    Tx.run(fn ->
      Locks.maint_shared!(run.workspace_id)
      :ok = Locks.graph!(run.workspace_id)
      task = Repo.one!(from(t in Task, where: t.id == ^run.task_id, lock: "FOR UPDATE"))

      if task.status == :new and claims_for?(task, run),
        do: auto_claim_locked(task, run),
        else: {:ok, :skipped}
    end)
  end

  # The run's agent is the assignee, or the run is as the squad that is
  # (`add-squads` decision 7). A delegated run never claims: the leader's
  # run has.
  defp claims_for?(%Task{assignee_id: id}, %Run{agent_id: id}), do: true

  defp claims_for?(%Task{assignee_id: id}, %Run{squad_id: squad_id})
       when is_integer(squad_id) and is_integer(id),
       do: Repo.exists?(from(s in Squad, where: s.id == ^squad_id and s.actor_id == ^id))

  defp claims_for?(_task, _run), do: false

  defp auto_claim_locked(task, run) do
    event =
      Repo.insert!(
        %TaskEvent{
          workspace_id: task.workspace_id,
          task_id: task.id,
          from_status: :new,
          to_status: :in_progress,
          actor_id: run.agent_id,
          commits: [],
          auto: true,
          source_run_id: run.id
        },
        on_conflict: :nothing
      )

    if event.id do
      agent = Repo.get!(Actor, run.agent_id)

      scope = %Scope{
        user: Repo.get!(Helmsman.Accounts.User, agent.owner_id),
        workspace: Repo.get!(Workspace, task.workspace_id),
        actor: agent,
        run: run
      }

      task = task |> Changeset.change(status: :in_progress) |> Repo.update!()

      with :ok <- TransitionSteps.run(task, event, scope) do
        task = preload_detail(task)
        notify_transition(task, Enum.find(task.events, &(&1.id == event.id)))
        {:ok, :claimed}
      end
    else
      {:ok, :skipped}
    end
  end

  @doc """
  Reopens the `verified` task `task_id` as the system
  (`add-continuation-triggers` decision 11): a server decision for a
  failed CI run or a merge conflict on its pull request
  (`add-pr-reconcile-merge`), not authorized by `Helmsman.Policy`.

  `attrs`: `verification_event_id`, the history entry of the verification
  the caller judged; `reason`, `:ci_failed` or `:merge_conflict`; and
  `content`, the explanation, written as a `review` by the system
  identity. In one transaction, in the order of `transition/4`
  (maintenance lock, graph lock, trigger targets, task row): the task
  must still be `verified` (else `{:error, {:status_changed, status}}`)
  and its latest move to `verified` must be `verification_event_id`
  (else `{:error, :stale}`); nothing is written otherwise. Then the review,
  the history entry `verified → in_progress` (`auto`, with `auto_reason`
  and the review), the steps of `Helmsman.Tasks.TransitionSteps`, a
  `reopen` trigger for the assignee and the notifications of
  `transition/4`.

  Returns `{:ok, %{task: detail, dispatch: outcomes}}`; `{:error, :busy}`
  as `transition/4`.
  """
  @spec auto_reopen(pos_integer(), %{
          verification_event_id: pos_integer(),
          reason: :ci_failed | :merge_conflict,
          content: String.t()
        }) :: {:ok, %{task: map(), dispatch: [Helmsman.Runs.Outcome.t()]}} | {:error, term()}
  def auto_reopen(task_id, %{verification_event_id: event_id, reason: reason, content: content})
      when is_integer(task_id) and reason in [:ci_failed, :merge_conflict] and
             is_binary(content) do
    {:ok, input} = Feedback.normalize(%{kind: :review, content: content})
    task = Repo.get!(Task, task_id)

    Tx.run(fn ->
      Locks.maint_shared!(task.workspace_id)
      :ok = Locks.graph!(task.workspace_id)
      scope = system_scope(task.workspace_id)

      with {:ok, task, plan} <-
             lock_targets(scope, task.ident, :in_progress, input, auto_reason: reason),
           :ok <- check_expected_from(task, :verified),
           :ok <- check_latest_verification(task, event_id) do
        auto_reopen_locked(scope, task, input, reason, plan)
      end
    end)
  end

  defp system_scope(workspace_id) do
    workspace = Repo.get!(Workspace, workspace_id)

    system =
      Repo.one!(from(a in Actor, where: a.workspace_id == ^workspace_id and a.kind == :system))

    %Scope{workspace: workspace, actor: system}
  end

  defp check_latest_verification(task, event_id) do
    latest =
      Repo.one(
        from(e in TaskEvent,
          where: e.task_id == ^task.id and e.to_status == :verified,
          select: max(e.id)
        )
      )

    if latest == event_id, do: :ok, else: {:error, :stale}
  end

  defp auto_reopen_locked(scope, task, input, reason, plan) do
    {entry, task} = insert_reason(task, scope, input, plan)

    event =
      Repo.insert!(%TaskEvent{
        workspace_id: task.workspace_id,
        task_id: task.id,
        from_status: :verified,
        to_status: :in_progress,
        actor_id: scope.actor.id,
        commits: [],
        auto: true,
        auto_reason: reason,
        feedback_id: entry.id
      })

    task = task |> Changeset.change(status: :in_progress) |> Repo.update!()

    with {:ok, detail} <- finish_transition(scope, task, event, entry, plan) do
      {:ok, %{task: Map.delete(detail, :dispatch), dispatch: detail.dispatch}}
    end
  end

  @doc """
  Cancels `task`, replaced by the task `replacer` (an ID), inside the
  caller's transaction, which holds the graph lock and `task`'s row lock
  (`Helmsman.Links.add/4`, `add-task-links` decision 5). Not authorized by
  `Helmsman.Policy` nor checked by the state machine, but always a legal
  transition: `task` is `new` or `in_progress`. The history entry is
  `auto`, by `scope.actor`, with the comment `replaced by <replacer>` and
  the run of a run scope; the steps (`Helmsman.Tasks.TransitionSteps`)
  and the notifications are those of `transition/4`. Runs on the task
  are left alone.
  """
  @spec cancel_replaced(Task.t(), String.t(), Scope.t()) :: :ok | {:error, term()}
  def cancel_replaced(
        %Task{status: from} = task,
        replacer,
        %Scope{actor: %Actor{} = actor} = scope
      )
      when from in [:new, :in_progress] and is_binary(replacer) do
    true = :cancelled in StateMachine.allowed(from)

    event =
      Repo.insert!(%TaskEvent{
        workspace_id: task.workspace_id,
        task_id: task.id,
        from_status: from,
        to_status: :cancelled,
        actor_id: actor.id,
        comment: "replaced by #{replacer}",
        commits: [],
        auto: true,
        source_run_id: source_run_id(scope)
      })

    task = task |> Changeset.change(status: :cancelled) |> Repo.update!()

    with :ok <- TransitionSteps.run(task, event, scope) do
      task = preload_detail(task)
      notify_transition(task, Enum.find(task.events, &(&1.id == event.id)))
    end
  end

  ## Assignee

  # `assignee` is an identity name of the workspace; nil or "" clears it,
  # a missing key keeps the current one.
  #
  # The named actor's row is locked `FOR SHARE` until the commit, as
  # `Helmsman.Actors.resolve_writer/2` does for the writer: disabling it
  # (removing its owner) waits for the assignment, or the assignment sees
  # it disabled. A managed agent's profile row is locked `FOR SHARE` next,
  # so archiving or rebinding it (profile `FOR UPDATE`) and dispatching
  # run one after the other. Actor and profile rows are locked after the
  # membership row and before the project and task rows (designs/01 §4).
  # The result is applied (and its error reported) after the version
  # check.
  defp lock_assignee(workspace_id, attrs) do
    case fetch_attr(attrs, :assignee) do
      :error -> :keep
      {:ok, name} when name in [nil, ""] -> {:set, nil}
      {:ok, name} when is_binary(name) -> lock_assignee_named(workspace_id, name)
      {:ok, _other} -> {:invalid, "is invalid"}
    end
  end

  defp lock_assignee_named(workspace_id, name) do
    query =
      from(a in Actor,
        where: a.workspace_id == ^workspace_id and a.name == ^name,
        lock: "FOR SHARE"
      )

    case Repo.one(query) do
      nil -> {:invalid, "does not exist"}
      %Actor{kind: :system} -> {:invalid, "cannot be the system identity"}
      %Actor{kind: :human, user_id: nil} -> {:invalid, "is not a member"}
      # A disabled squad is refused like any disabled identity (`add-squads`
      # decision 15).
      %Actor{disabled_at: %DateTime{}} -> {:invalid, "is disabled"}
      %Actor{kind: :squad, id: id} -> lock_squad(id)
      %Actor{kind: :agent, id: id} -> lock_profile(id)
      %Actor{id: id} -> {:set, id}
    end
  end

  # The rows a squad's dispatch reads (`add-squads` decision 6): its
  # leader and members, the squad row and their profiles, before the task.
  # Its leader and members kept changing: `{:error, :busy}`.
  defp lock_squad(actor_id) do
    case SquadDispatch.lock_rows(actor_id) do
      {:error, :busy} = busy -> busy
      _locked -> {:set, actor_id}
    end
  end

  defp not_busy({:error, :busy} = busy), do: busy
  defp not_busy(_assignee), do: :ok

  # An archived profile has a disabled actor: never reached for one.
  defp lock_profile(actor_id) do
    Repo.one(from(p in AgentProfile, where: p.actor_id == ^actor_id, lock: "FOR SHARE"))
    {:set, actor_id}
  end

  defp put_assignee(changeset, :keep), do: changeset
  # The squad's rows kept changing: `not_busy/1` returns the error.
  defp put_assignee(changeset, {:error, :busy}), do: changeset
  defp put_assignee(changeset, {:set, id}), do: Changeset.put_change(changeset, :assignee_id, id)

  defp put_assignee(changeset, {:invalid, message}),
    do: Changeset.add_error(changeset, :assignee, message)

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  ## Notifications

  defp notify(event, %Task{} = task) do
    Events.after_commit(Events.topic(:project, task.project_id), {event, summary(task)})
    Events.after_commit(Events.topic(:task, task.id), {:task_updated, task.ident})
  end

  @doc """
  Registers `{:task_updated, summary}` on the project topic for after the
  commit, for a write to `task` made by another module (a system comment
  of `Helmsman.Runs`).
  """
  @spec notify_summary(Task.t()) :: :ok
  def notify_summary(%Task{} = task) do
    Events.after_commit(
      Events.topic(:project, task.project_id),
      {:task_updated, summary(load_summary(task))}
    )
  end

  defp notify_transition(%Task{} = task, %TaskEvent{} = event) do
    Events.after_commit(Events.topic(:project, task.project_id), {:task_updated, summary(task)})

    Events.after_commit(
      Events.topic(:task, task.id),
      {:task_transitioned, %{ident: task.ident, event: event_view(event)}}
    )
  end

  ## External form

  @doc """
  The summary map of a task (MCP, web, notifications). Needs `created_by`
  and `assignee` preloaded and `commits` filled in, as every task returned
  by this module has.
  """
  @spec summary(Task.t()) :: summary()
  def summary(%Task{} = task) do
    %{
      id: task.ident,
      project_key: project_key(task.ident),
      title: task.title,
      status: Atom.to_string(task.status),
      priority: Atom.to_string(task.priority),
      labels: task.labels,
      created_by: actor_ref(task.created_by),
      assignee: actor_ref(task.assignee),
      lock_version: task.lock_version,
      kind: Atom.to_string(task.kind),
      epic: task.epic_ident,
      progress: task.progress,
      commits: task.commits,
      feedback_count: task.feedback_count,
      open_question: task.open_question,
      blocked: task.blocked,
      created_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  @doc """
  The detail map of a task: the summary plus `description`, `history`
  (oldest first), `feedback` (every record, superseded ones included,
  by number; `Helmsman.Feedback.view/1`), `children` (an epic's steps'
  summaries in creation order, in every project; `nil` for a task),
  `epic_title` (the title of a task's epic; `nil` without one and for an
  epic) and `links` (`Helmsman.Links.for_task/1`). Needs the preloads of
  `get/2`.
  """
  @spec detail(Task.t()) :: map()
  def detail(%Task{} = task) do
    task
    |> summary()
    |> Map.merge(%{
      description: task.description,
      history: Enum.map(task.events, &event_view/1),
      feedback: Enum.map(task.feedback, &Feedback.view/1),
      children: task.children && Enum.map(task.children, &summary/1),
      epic_title: task.epic_title,
      links: task.links
    })
  end

  @doc """
  The external form of a history entry, in `detail/1` and in the
  `:task_transitioned` notification; `feedback` is the ID of its reason.
  Needs `actor` preloaded and `feedback_ident` filled in, as the tasks of
  `get/2` have.
  """
  @spec event_view(TaskEvent.t()) :: event_view()
  def event_view(%TaskEvent{} = event) do
    %{
      from: event.from_status && Atom.to_string(event.from_status),
      to: Atom.to_string(event.to_status),
      actor: actor_ref(event.actor),
      comment: event.comment,
      commits: event.commits,
      tests: tests_view(event.tests),
      auto: event.auto,
      feedback: event.feedback_ident,
      verified_sha: event.verified_sha,
      at: event.inserted_at
    }
  end

  defp tests_view(nil), do: nil

  defp tests_view(%{} = tests),
    do: %{command: tests["command"], passed: tests["passed"], summary: tests["summary"]}

  # Keys never contain "-".
  defp project_key(ident), do: ident |> String.split("-", parts: 2) |> hd()

  defp actor_ref(nil), do: nil

  defp actor_ref(%Actor{name: name, kind: kind, user_id: user_id}),
    do: %{name: name, kind: Atom.to_string(kind), unclaimed: kind == :human and is_nil(user_id)}

  @doc """
  Loads what `summary/1` needs into `task` (creator, assignee, commits,
  epic, progress, blocked).
  """
  @spec load_summary(Task.t()) :: Task.t()
  def load_summary(%Task{} = task), do: hd(load_summaries([task]))

  @doc "`load_summary/1` for every task in `tasks`, in a fixed number of queries."
  @spec load_summaries([Task.t()]) :: [Task.t()]
  def load_summaries(tasks) when is_list(tasks) do
    tasks
    |> Repo.preload([:created_by, :assignee], force: true)
    |> Enum.map(&mark_task_actors/1)
    |> put_derived()
    |> Links.put_blocked()
  end

  defp mark_actor(nil), do: nil

  defp mark_actor(%Actor{} = actor),
    do: %{actor | unclaimed: actor.kind == :human and is_nil(actor.user_id)}

  defp mark_task_actors(task),
    do: %{task | created_by: mark_actor(task.created_by), assignee: mark_actor(task.assignee)}

  @doc """
  Loads what `detail/1` needs into `task` (as `get/2` returns it), inside
  or outside a transaction, without authorization.
  """
  @spec load_detail(Task.t()) :: Task.t()
  def load_detail(%Task{} = task), do: preload_detail(task)

  defp preload_detail(task) do
    events = from(e in TaskEvent, order_by: [asc: e.inserted_at, asc: e.id], preload: :actor)
    task = Repo.preload(task, [:created_by, :assignee, events: events], force: true)
    task = mark_task_actors(task)
    feedback = Enum.map(Feedback.for_task(task), &%{&1 | author: mark_actor(&1.author)})
    ids = Map.new(feedback, &{&1.id, Feedback.Id.build(task.ident, &1.seq)})

    events =
      Enum.map(
        task.events,
        &%{&1 | feedback_ident: ids[&1.feedback_id], actor: mark_actor(&1.actor)}
      )

    task = %{
      task
      | events: events,
        feedback: feedback,
        links: Links.for_task(task),
        commits: events |> Enum.flat_map(& &1.commits) |> Enum.uniq()
    }

    [task] = [task] |> put_epic_fields() |> Links.put_blocked()
    put_family(task)
  end

  defp put_family(%Task{kind: :epic} = epic) do
    children =
      from(t in Task,
        where: t.workspace_id == ^epic.workspace_id and t.epic_id == ^epic.id,
        order_by: [asc: t.id],
        preload: [:created_by, :assignee]
      )
      |> Repo.all()
      |> put_commits()
      |> Links.put_blocked()
      |> Enum.map(&%{&1 | epic_ident: epic.ident})

    %{epic | children: children, epic_title: nil}
  end

  defp put_family(%Task{epic_id: nil} = task), do: %{task | children: nil, epic_title: nil}

  defp put_family(%Task{epic_id: epic_id} = task) do
    title = Repo.one!(from(t in Task, where: t.id == ^epic_id, select: t.title))
    %{task | children: nil, epic_title: title}
  end

  defp put_derived(tasks), do: tasks |> put_commits() |> put_epic_fields()

  # At most two queries for all `tasks`: the IDs of their epics (only when
  # some belong to one) and the progress of the epics among them (only
  # when there are some).
  defp put_epic_fields([]), do: []

  defp put_epic_fields([%Task{workspace_id: workspace_id} | _] = tasks) do
    epic_ids = tasks |> Enum.map(& &1.epic_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    idents =
      if epic_ids == [],
        do: %{},
        else:
          Map.new(Repo.all(from(t in Task, where: t.id in ^epic_ids, select: {t.id, t.ident})))

    progress = Epics.progress(workspace_id, for(%Task{kind: :epic, id: id} <- tasks, do: id))

    Enum.map(tasks, &%{&1 | epic_ident: idents[&1.epic_id], progress: progress[&1.id]})
  end

  # One query for the commits of all `tasks`, whatever their number.
  defp put_commits([]), do: []

  defp put_commits(tasks) do
    ids = Enum.map(tasks, & &1.id)

    commits =
      from(e in TaskEvent,
        where: e.task_id in ^ids and fragment("cardinality(?) > 0", e.commits),
        order_by: [asc: e.inserted_at, asc: e.id],
        select: {e.task_id, e.commits}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(tasks, fn task ->
      %{task | commits: commits |> Map.get(task.id, []) |> List.flatten() |> Enum.uniq()}
    end)
  end
end
