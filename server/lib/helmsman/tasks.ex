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
  alias Helmsman.Events
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Projects
  alias Helmsman.Projects.Project
  alias Helmsman.Repo

  alias Helmsman.Tasks.{
    Evidence,
    Ident,
    StateMachine,
    Task,
    TaskEvent,
    TransitionContext,
    TransitionSteps
  }

  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  @type error :: Changeset.t() | :forbidden | :not_found | :no_actor | atom()
  @type actor_ref :: %{name: String.t(), kind: String.t()} | nil
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
          commits: [String.t()],
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
          at: DateTime.t()
        }

  @default_limit 50
  @max_limit 200

  ## Creating

  @doc """
  Creates a task in the project with `project_key` (`:create_task`).

  `attrs`: `title`, `description`, `priority`, `labels` and `assignee` (an
  identity name; `nil` or `""` for none). The task starts as `new`, created
  by `scope.actor`, with a creation entry in its history.

  Returns `{:error, :not_found}` for an unknown project and
  `{:error, :project_archived}` for an archived one.
  """
  @spec create(Scope.t(), String.t(), map()) :: {:ok, Task.t()} | {:error, error()}
  def create(%Scope{actor: nil}, _project_key, _attrs), do: {:error, :no_actor}

  def create(%Scope{workspace: %Workspace{}} = scope, project_key, attrs)
      when is_binary(project_key) and is_map(attrs) do
    Workspaces.write_transaction(scope, :create_task, fn scope ->
      assignee = lock_assignee(scope.workspace.id, attrs)
      test_hook(:assignee_locked)

      changeset =
        %Task{workspace_id: scope.workspace.id, created_by_id: scope.actor.id}
        |> Task.changeset(attrs)
        |> put_assignee(assignee)

      with {:ok, project} <- fetch_project(scope, project_key),
           :ok <- validate(changeset),
           {:ok, seq} <- allocate_seq(project) do
        test_hook(:seq_allocated)
        insert_task(scope, changeset, project, seq)
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

  defp insert_task(scope, changeset, project, seq) do
    changeset =
      Changeset.change(changeset,
        project_id: project.id,
        seq: seq,
        ident: Ident.build(project.key, seq)
      )

    with {:ok, task} <- Repo.insert(changeset) do
      Repo.insert!(%TaskEvent{
        workspace_id: task.workspace_id,
        task_id: task.id,
        from_status: nil,
        to_status: :new,
        actor_id: scope.actor.id
      })

      task = preload_detail(task)
      notify(:task_created, task)
      {:ok, task}
    end
  end

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
  Lists the tasks of the project with `project_key`, most recently updated
  first.

  ## Options

    * `:status` - a status or a list of statuses
    * `:label` - only tasks with this label
    * `:assignee` - an identity name; `""` for unassigned tasks
    * `:limit` - at most this many tasks (default 50, at most 200)
    * `:offset` - skip this many tasks (default 0)

  Returns `{:error, :not_found}` for an unknown project.
  """
  @spec list(Scope.t(), String.t(), keyword()) ::
          {:ok, [Task.t()]} | {:error, :forbidden | :not_found}
  def list(%Scope{workspace: %Workspace{id: workspace_id}} = scope, project_key, opts \\ [])
      when is_binary(project_key) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, project} <- fetch_project(scope, project_key) do
      tasks =
        from(t in Task,
          where: t.workspace_id == ^workspace_id and t.project_id == ^project.id,
          order_by: [desc: t.updated_at, desc: t.id],
          limit: ^limit(opts[:limit]),
          offset: ^offset(opts[:offset]),
          preload: [:created_by, :assignee]
        )
        |> filter_status(opts[:status])
        |> filter_label(opts[:label])
        |> filter_assignee(workspace_id, opts[:assignee])
        |> Repo.all()
        |> put_commits()

      {:ok, tasks}
    end
  end

  defp limit(n) when is_integer(n), do: n |> max(0) |> min(@max_limit)
  defp limit(_), do: @default_limit

  defp offset(n) when is_integer(n) and n > 0, do: n
  defp offset(_), do: 0

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

  ## Editing

  @doc """
  Edits a task's title, description, priority, labels and assignee
  (`:update_task`); `status` and every other field in `attrs` are ignored.

  With a `lock_version` that is not the current one the result is
  `{:error, :stale}`, checked before anything else. Without one the edit
  applies to the latest version (last write wins). An edit that changes
  something bumps `lock_version` and notifies; one that changes nothing
  returns the task as it is.
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
           assignee = lock_assignee(scope.workspace.id, attrs),
           _ = test_hook(:assignee_locked),
           {:ok, task} <- lock_task(scope.workspace.id, ident),
           :ok <- check_version(task, lock_version) do
        task
        |> Task.changeset(attrs)
        |> put_assignee(assignee)
        |> save()
      end
    end)
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

  defp save(%Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp save(%Changeset{changes: changes} = changeset) when changes == %{},
    do: {:ok, preload_detail(changeset.data)}

  defp save(changeset) do
    changeset = Changeset.change(changeset, lock_version: changeset.data.lock_version + 1)

    with {:ok, task} <- Repo.update(changeset) do
      task = preload_detail(task)
      notify(:task_updated, task)
      {:ok, task}
    end
  end

  ## Transitions

  @doc """
  Moves the task `ident` to the status `to` (`:transition_task`) and
  returns its detail (`detail/1`).

  `to` is read by `Helmsman.Tasks.StateMachine.normalize/1`; `opts` (a map
  or keyword list) may carry `comment`, `commits` and `tests`, checked by
  `Helmsman.Tasks.Evidence.normalize/1`. Both are checked before the
  transaction starts.

  In one transaction, after the maintenance lock and the membership row:
  the workspace graph lock, the task row `FOR UPDATE`, the check context
  (`Helmsman.Tasks.TransitionContext`), `Helmsman.Tasks.StateMachine.check/3`,
  the history entry, the new status and the steps of
  `Helmsman.Tasks.TransitionSteps`. Concurrent transitions of a task run
  one after the other, each checked against the status the previous one
  committed.

  Moving a `new` task without an assignee to `in_progress` claims it: the
  acting identity becomes the assignee and `lock_version` grows by one.
  Other transitions leave both unchanged.

  After the commit `{:task_updated, summary}` is broadcast on the project
  topic and `{:task_transitioned, %{ident: ident, event: event}}` on the
  task topic, `event` being the new history entry (`event_view/1`).

  Errors: `{:invalid_status, input, valid}`, `{:invalid_comment, _}`,
  `{:invalid_commits, bad}`, `{:invalid_tests, _}`, `:forbidden`,
  `:not_found`, `:no_actor` and the reasons of `StateMachine.check/3`
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
         {:ok, evidence} <- Evidence.normalize(opts) do
      Workspaces.write_transaction(scope, :transition_task, fn scope ->
        transition_locked(scope, ident, to, evidence)
      end)
    end
  end

  # Lock order: maintenance lock, membership row (write_transaction), graph
  # lock, task row (designs/01 §4).
  defp transition_locked(scope, ident, to, evidence) do
    with {:ok, ident, _key, _seq} <- Ident.parse(ident),
         :ok <- Locks.graph!(scope.workspace.id),
         {:ok, task} <- lock_task(scope.workspace.id, ident),
         ctx = TransitionContext.build(task, scope, to, evidence),
         :ok <- StateMachine.check(task.status, to, ctx) do
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
          auto: false
        })

      task = task |> Changeset.change(transition_changes(task, to, scope)) |> Repo.update!()

      with :ok <- TransitionSteps.run(task, event, scope) do
        task = preload_detail(task)
        event = Enum.find(task.events, &(&1.id == event.id))
        notify_transition(task, event)
        {:ok, detail(task)}
      end
    end
  end

  # Claiming is the only transition that edits a field, so the only one
  # that bumps the version: a status change alone must not make concurrent
  # field edits stale.
  defp transition_changes(%Task{status: :new, assignee_id: nil} = task, :in_progress, scope),
    do: [status: :in_progress, assignee_id: scope.actor.id, lock_version: task.lock_version + 1]

  defp transition_changes(_task, to, _scope), do: [status: to]

  ## Assignee

  # `assignee` is an identity name of the workspace; nil or "" clears it,
  # a missing key keeps the current one.
  #
  # The named actor's row is locked `FOR SHARE` until the commit, as
  # `Helmsman.Actors.resolve_writer/2` does for the writer: disabling it
  # (removing its owner) waits for the assignment, or the assignment sees
  # it disabled. Actor rows are locked after the membership row and before
  # the project and task rows. The result is applied (and its error
  # reported) after the version check.
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
      %Actor{disabled_at: %DateTime{}} -> {:invalid, "is disabled"}
      %Actor{id: id} -> {:set, id}
    end
  end

  defp put_assignee(changeset, :keep), do: changeset
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
      commits: task.commits,
      created_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  @doc """
  The detail map of a task: the summary plus `description` and `history`
  (oldest first). Needs the preloads of `get/2`.
  """
  @spec detail(Task.t()) :: map()
  def detail(%Task{} = task) do
    task
    |> summary()
    |> Map.merge(%{description: task.description, history: Enum.map(task.events, &event_view/1)})
  end

  @doc """
  The external form of a history entry, in `detail/1` and in the
  `:task_transitioned` notification. Needs `actor` preloaded.
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
      at: event.inserted_at
    }
  end

  defp tests_view(nil), do: nil

  defp tests_view(%{} = tests),
    do: %{command: tests["command"], passed: tests["passed"], summary: tests["summary"]}

  # Keys never contain "-".
  defp project_key(ident), do: ident |> String.split("-", parts: 2) |> hd()

  defp actor_ref(nil), do: nil
  defp actor_ref(%Actor{name: name, kind: kind}), do: %{name: name, kind: Atom.to_string(kind)}

  defp preload_detail(task) do
    events = from(e in TaskEvent, order_by: [asc: e.inserted_at, asc: e.id], preload: :actor)
    task = Repo.preload(task, [:created_by, :assignee, events: events], force: true)
    %{task | commits: task.events |> Enum.flat_map(& &1.commits) |> Enum.uniq()}
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
