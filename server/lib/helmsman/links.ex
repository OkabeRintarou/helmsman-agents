defmodule Helmsman.Links do
  @moduledoc """
  Task links (designs/07): `replaces` (A takes over B) and `depends_on`
  (A waits for B), directed, between two tasks of one workspace (any
  projects).

  Adding and removing a link run in a write transaction under the
  workspace graph lock, with both task rows locked `FOR UPDATE` by
  primary key (designs/01 §4), like every transition: two concurrent
  requests can never form a `depends_on` cycle together, and what a
  transition check reads (`blockers/1`, `replaced_by/1`) is stable.

  Whether a prerequisite is satisfied is defined here only:
  `satisfied?/1` for a loaded task and `unsatisfied_dependency/1` for the
  SQL of lists, both from `@satisfied`; `blockers/1` and `put_blocked/1`
  use the same condition.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Links.Link
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Ident, Task, TaskEvent}
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  # A prerequisite in one of these statuses is satisfied (this change;
  # `add-dependency-dispatch` extends the rule here, and only here).
  @satisfied [:done, :verified]
  # A task replaced while in one of these is cancelled.
  @open [:new, :in_progress]

  @type type :: Link.type()
  @type link_view :: %{
          type: String.t(),
          direction: String.t(),
          task: String.t(),
          title: String.t(),
          status: String.t(),
          kind: String.t(),
          actor: %{name: String.t(), kind: String.t()},
          created_at: DateTime.t()
        }
  @type error ::
          :no_actor
          | :forbidden
          | :not_found
          | :self_link
          | {:not_found, String.t()}
          | {:invalid_type, term()}
          | {:cycle, [String.t()]}
          | {:forbidden, {:cancels_other_task, String.t(), String.t()}}

  ## Writing

  @doc """
  Adds the link `from → to` of `type` (`:link_tasks`) and returns the
  detail of `from` (`Helmsman.Tasks.detail/1`).

  `from` and `to` are task IDs (any case). `type` is `depends_on` or
  `replaces`, case-insensitive, dashes and spaces read as underscores
  (atoms too); anything else is `{:error, {:invalid_type, input}}`. An
  unknown task is `{:error, {:not_found, ident}}` naming the end that is
  missing (`from` first); `from == to` is `{:error, :self_link}`.

  A link that exists already changes nothing: no history, no
  notification, no cancellation. A new `depends_on` that would close a
  cycle is `{:error, {:cycle, [A, B, ..., A]}}`. A new `replaces` cancels
  `to` while it is `new` or `in_progress` (`Helmsman.Tasks.cancel_replaced/3`).

  A run scope must have one end as its own task; it may not replace
  another task that is still `new` or `in_progress`
  (`{:error, {:forbidden, {:cancels_other_task, to, own}}}`).

  After the commit, when a link was added: `{:links_changed, ident}` on
  the topic of each end and `{:task_updated, summary}` of `from` on its
  project topic.
  """
  @spec add(Scope.t(), String.t(), String.t(), term()) :: {:ok, map()} | {:error, error()}
  def add(scope, from, to, type), do: write(scope, :add, from, to, type)

  @doc """
  Removes the link `from → to` of `type` (`:link_tasks`) and returns the
  detail of `from`. Removing a link that does not exist succeeds without
  any notification; removing one never changes a status (a replaced
  task stays `cancelled`). Inputs, errors and notifications as `add/4`;
  a run scope must have one end as its own task.
  """
  @spec remove(Scope.t(), String.t(), String.t(), term()) :: {:ok, map()} | {:error, error()}
  def remove(scope, from, to, type), do: write(scope, :remove, from, to, type)

  defp write(%Scope{actor: nil}, _op, _from, _to, _type), do: {:error, :no_actor}

  defp write(%Scope{workspace: %Workspace{}} = scope, op, from, to, type) do
    with {:ok, type} <- normalize_type(type),
         {:ok, from} <- parse_ident(from),
         {:ok, to} <- parse_ident(to),
         :ok <- check_not_self(from, to) do
      Workspaces.write_transaction(scope, :link_tasks, fn scope ->
        write_locked(scope, op, {from, to}, type)
      end)
    end
  end

  # Lock order: maintenance lock, membership row (write_transaction), graph
  # lock, task rows by primary key (designs/01 §4).
  defp write_locked(scope, op, {from, to}, type) do
    with :ok <- Locks.graph!(scope.workspace.id),
         {:ok, a, b} <- lock_ends(scope.workspace.id, from, to),
         :ok <- Policy.authorize(scope, :link_tasks, {a, b}),
         {:ok, changed?} <- apply_op(op, scope, a, b, type) do
      # Re-read: replacing a step of `from`'s own epic may have moved it
      # (`Helmsman.Tasks.Epics.recompute/3`).
      task = a |> Repo.reload!() |> Tasks.load_detail()
      if changed?, do: notify_links_changed(task, b)
      {:ok, Tasks.detail(task)}
    end
  end

  @doc """
  Reads a link type: `depends_on` or `replaces`, case-insensitive,
  surrounding blanks ignored, dashes and spaces read as underscores.

      iex> Helmsman.Links.normalize_type("Depends-On")
      {:ok, :depends_on}
  """
  @spec normalize_type(term()) :: {:ok, type()} | {:error, {:invalid_type, term()}}
  def normalize_type(input) when is_atom(input) and input not in [nil, true, false],
    do: input |> Atom.to_string() |> lookup_type(input)

  def normalize_type(input) when is_binary(input), do: lookup_type(input, input)
  def normalize_type(input), do: {:error, {:invalid_type, input}}

  defp lookup_type(string, input) do
    case string |> String.trim() |> String.downcase() |> String.replace([" ", "-"], "_") do
      "depends_on" -> {:ok, :depends_on}
      "replaces" -> {:ok, :replaces}
      _other -> {:error, {:invalid_type, input}}
    end
  end

  defp parse_ident(ident) when is_binary(ident) do
    case Ident.parse(ident) do
      {:ok, canonical, _key, _seq} -> {:ok, canonical}
      {:error, :not_found} -> {:error, {:not_found, ident |> String.trim() |> String.upcase()}}
    end
  end

  defp parse_ident(ident), do: {:error, {:not_found, inspect(ident)}}

  defp check_not_self(ident, ident), do: {:error, :self_link}
  defp check_not_self(_from, _to), do: :ok

  defp lock_ends(workspace_id, from, to) do
    tasks =
      from(t in Task,
        where: t.workspace_id == ^workspace_id and t.ident in ^[from, to],
        order_by: [asc: t.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()
      |> Map.new(&{&1.ident, &1})

    case tasks do
      %{^from => a, ^to => b} -> {:ok, a, b}
      %{^from => _} -> {:error, {:not_found, to}}
      _missing -> {:error, {:not_found, from}}
    end
  end

  defp apply_op(:add, scope, a, b, :depends_on) do
    case cycle(a, b) do
      nil ->
        test_hook(:link_checked)
        {:ok, insert(a, b, :depends_on, scope.actor.id)}

      path ->
        {:error, {:cycle, path}}
    end
  end

  defp apply_op(:add, scope, a, b, :replaces) do
    with :ok <- check_replace(scope, a, b) do
      test_hook(:link_checked)

      if insert(a, b, :replaces, scope.actor.id),
        do: cancel_replaced(scope, a, b),
        else: {:ok, false}
    end
  end

  defp apply_op(:remove, _scope, a, b, type) do
    {count, _} =
      from(l in Link,
        where: l.from_task_id == ^a.id and l.to_task_id == ^b.id and l.type == ^type
      )
      |> Repo.delete_all()

    {:ok, count == 1}
  end

  defp cancel_replaced(scope, a, %Task{status: status} = b) when status in @open do
    with :ok <- Tasks.cancel_replaced(b, a.ident, scope), do: {:ok, true}
  end

  defp cancel_replaced(_scope, _a, _b), do: {:ok, true}

  # True when the link is new.
  defp insert(a, b, type, actor_id) do
    {count, _} =
      Repo.insert_all(
        Link,
        [
          %{
            workspace_id: a.workspace_id,
            from_task_id: a.id,
            to_task_id: b.id,
            type: type,
            actor_id: actor_id
          }
        ],
        on_conflict: :nothing
      )

    count == 1
  end

  # A run may not cancel a task other than its own by replacing it
  # (designs/13 §2.3: a run's reach is its own task).
  defp check_replace(%Scope{via: :run, run: %Run{task_id: own}}, a, %Task{id: id} = b)
       when id != own and b.status in @open,
       do: {:error, {:forbidden, {:cancels_other_task, b.ident, a.ident}}}

  defp check_replace(_scope, _a, _b), do: :ok

  # The shortest `depends_on` path from `b` back to `a`, if any, as IDs
  # `[A, B, ..., A]` (designs/07 §2).
  defp cycle(a, b) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE reach(id, path) AS (
          SELECT to_task_id, ARRAY[from_task_id, to_task_id]
            FROM task_links WHERE from_task_id = $1 AND type = 'depends_on'
          UNION ALL
          SELECT l.to_task_id, r.path || l.to_task_id
            FROM task_links l JOIN reach r ON l.from_task_id = r.id
           WHERE l.type = 'depends_on' AND NOT l.to_task_id = ANY(r.path)
        )
        SELECT path FROM reach WHERE id = $2 LIMIT 1
        """,
        [b.id, a.id]
      )

    case rows do
      [] ->
        nil

      [[path]] ->
        idents =
          from(t in Task, where: t.id in ^path, select: {t.id, t.ident})
          |> Repo.all()
          |> Map.new()

        Enum.map([a.id | path], &Map.fetch!(idents, &1))
    end
  end

  ## Satisfaction and blockers

  @doc """
  Whether the prerequisite `task` is satisfied: it is `done` or
  `verified`. The single definition, with `unsatisfied_dependency/1`.
  """
  @spec satisfied?(Task.t()) :: boolean()
  def satisfied?(%Task{status: status}), do: status in @satisfied

  @doc """
  The condition "the task bound as `binding` has an outgoing `depends_on`
  whose prerequisite is not satisfied" (`satisfied?/1`), as an `EXISTS`
  for the query's own `WHERE` or `SELECT`: lists compute `blocked` in
  their single query.
  """
  @spec unsatisfied_dependency(atom()) :: Ecto.Query.dynamic_expr()
  def unsatisfied_dependency(binding \\ :task) when is_atom(binding) do
    prereqs =
      from([link: l] in unsatisfied_prereqs(),
        where: l.from_task_id == parent_as(^binding).id,
        select: 1
      )

    dynamic(exists(subquery(prereqs)))
  end

  defp unsatisfied_prereqs do
    from(l in Link,
      as: :link,
      join: p in Task,
      as: :prereq,
      on: p.id == l.to_task_id,
      where: l.type == :depends_on and p.status not in ^@satisfied
    )
  end

  @doc """
  The IDs of the unsatisfied prerequisites of the task `task_id`, by
  internal ID.
  """
  @spec blockers(pos_integer()) :: [String.t()]
  def blockers(task_id) when is_integer(task_id) do
    from([link: l, prereq: p] in unsatisfied_prereqs(),
      where: l.from_task_id == ^task_id,
      order_by: [asc: p.id],
      select: p.ident
    )
    |> Repo.all()
  end

  @doc "The IDs of the tasks replacing the task `task_id`, by internal ID."
  @spec replaced_by(pos_integer()) :: [String.t()]
  def replaced_by(task_id) when is_integer(task_id) do
    from(l in Link,
      join: t in Task,
      on: t.id == l.from_task_id,
      where: l.to_task_id == ^task_id and l.type == :replaces,
      order_by: [asc: t.id],
      select: t.ident
    )
    |> Repo.all()
  end

  @doc "Fills in `blocked` of every task in `tasks`, in one query."
  @spec put_blocked([Task.t()]) :: [Task.t()]
  def put_blocked([]), do: []

  def put_blocked(tasks) do
    ids = Enum.map(tasks, & &1.id)

    blocked =
      from(t in Task,
        as: :task,
        where: t.id in ^ids,
        where: ^unsatisfied_dependency(:task),
        select: t.id
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.map(tasks, &%{&1 | blocked: MapSet.member?(blocked, &1.id)})
  end

  ## Reading

  @doc """
  Every link of `task`, outgoing first, then by type (`depends_on`,
  `replaces`) and by the other task's internal ID: `type`, `direction`
  (`"out"` / `"in"`), the other task's `task` (ID), `title`, `status` and
  `kind` (`"task"` / `"epic"`), the `actor` who added it and `created_at`.
  """
  @spec for_task(Task.t()) :: [link_view()]
  def for_task(%Task{id: id}) do
    from(l in Link,
      join: p in Task,
      on:
        p.id ==
          fragment(
            "CASE WHEN ? = ? THEN ? ELSE ? END",
            l.from_task_id,
            type(^id, :integer),
            l.to_task_id,
            l.from_task_id
          ),
      join: a in Actor,
      on: a.id == l.actor_id,
      where: l.from_task_id == ^id or l.to_task_id == ^id,
      select: {l, p, a}
    )
    |> Repo.all()
    |> Enum.sort_by(fn {l, p, _a} ->
      {if(l.from_task_id == id, do: 0, else: 1), type_rank(l.type), p.id}
    end)
    |> Enum.map(fn {l, p, a} ->
      %{
        type: Atom.to_string(l.type),
        direction: if(l.from_task_id == id, do: "out", else: "in"),
        task: p.ident,
        title: p.title,
        status: Atom.to_string(p.status),
        kind: Atom.to_string(p.kind),
        actor: %{name: a.name, kind: Atom.to_string(a.kind)},
        created_at: l.inserted_at
      }
    end)
  end

  defp type_rank(type), do: Enum.find_index(Link.types(), &(&1 == type))

  ## Notifications

  @doc """
  The `Helmsman.Tasks.TransitionSteps` step: `status_changed/3` for the
  transition just written.
  """
  @spec after_transition(Task.t(), TaskEvent.t(), Scope.t()) :: :ok
  def after_transition(%Task{} = task, %TaskEvent{} = event, _scope),
    do: status_changed(task, event.from_status, event.to_status)

  @doc """
  The single entry point for "a prerequisite's status changed": when
  `task` moving from `from` to `to` flips `satisfied?/1`, registers for
  after the commit, for every task depending on it, `{:task_updated,
  summary}` on its project topic and `{:links_changed, ident}` on its
  topic. Reads and notifies only: nothing is written, no run is started.
  Called inside the transaction that changed the status.
  """
  @spec status_changed(Task.t(), Task.status() | nil, Task.status()) :: :ok
  def status_changed(%Task{} = task, from, to) do
    if satisfied?(%{task | status: from}) != satisfied?(%{task | status: to}) do
      from(t in Task,
        join: l in Link,
        on: l.from_task_id == t.id,
        where: l.to_task_id == ^task.id and l.type == :depends_on,
        order_by: [asc: t.id]
      )
      |> Repo.all()
      |> Tasks.load_summaries()
      |> Enum.each(fn dependent ->
        Events.after_commit(
          Events.topic(:project, dependent.project_id),
          {:task_updated, Tasks.summary(dependent)}
        )

        Events.after_commit(
          Events.topic(:task, dependent.id),
          {:links_changed, dependent.ident}
        )
      end)
    end

    :ok
  end

  defp notify_links_changed(%Task{} = a, %Task{} = b) do
    Events.after_commit(Events.topic(:task, a.id), {:links_changed, a.ident})
    Events.after_commit(Events.topic(:task, b.id), {:links_changed, b.ident})
    Events.after_commit(Events.topic(:project, a.project_id), {:task_updated, Tasks.summary(a)})
  end

  # Fault injection for the concurrency tests: compiled in the test
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
end
