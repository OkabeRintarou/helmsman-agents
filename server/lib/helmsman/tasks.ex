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
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Policy
  alias Helmsman.Projects
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Tasks.{Ident, Task, TaskEvent}
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
          created_at: DateTime.t(),
          updated_at: DateTime.t()
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

  ## External form

  @doc """
  The summary map of a task (MCP, web, notifications). Needs `created_by`
  and `assignee` preloaded.
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
    history =
      Enum.map(task.events, fn event ->
        %{
          from: event.from_status && Atom.to_string(event.from_status),
          to: Atom.to_string(event.to_status),
          actor: actor_ref(event.actor),
          comment: event.comment,
          at: event.inserted_at
        }
      end)

    task
    |> summary()
    |> Map.merge(%{description: task.description, history: history})
  end

  # Keys never contain "-".
  defp project_key(ident), do: ident |> String.split("-", parts: 2) |> hd()

  defp actor_ref(nil), do: nil
  defp actor_ref(%Actor{name: name, kind: kind}), do: %{name: name, kind: Atom.to_string(kind)}

  defp preload_detail(task) do
    events = from(e in TaskEvent, order_by: [asc: e.inserted_at, asc: e.id], preload: :actor)
    Repo.preload(task, [:created_by, :assignee, events: events], force: true)
  end
end
