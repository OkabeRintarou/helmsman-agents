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
  alias Helmsman.Dispatch.Dependencies
  alias Helmsman.Events
  alias Helmsman.Links.Link
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias Helmsman.Squads.Orchestration
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Ident, Task, TaskEvent}
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  # A prerequisite must be in one of these statuses to be satisfied (the
  # first condition of `waiting_for/1`).
  @satisfied [:done, :verified]
  # A task replaced while in one of these is cancelled.
  @open [:new, :in_progress]

  # The single definition of "satisfied" (`waiting_for/1`), as SQL on the
  # task `t` given by its `id`, `project_id`, `status` and `kind`.
  active_sql = fn t ->
    "EXISTS (SELECT 1 FROM runs ar WHERE ar.task_id = #{t}.id " <>
      "AND ar.status IN ('claimed', 'running', 'cancelling'))"
  end

  code_waiting_sql = fn t ->
    """
    EXISTS (SELECT 1 FROM projects pj
      CROSS JOIN LATERAL (SELECT dr.head_sha FROM runs dr
        WHERE dr.task_id = #{t}.id AND dr.push_status = 'pushed'
          AND (dr.repository_id = pj.repository_id
               OR dr.local_repository_id = pj.local_repository_id)
        ORDER BY dr.claimed_at DESC, dr.id DESC LIMIT 1) d
      WHERE pj.id = #{t}.project_id
        AND NOT EXISTS (SELECT 1 FROM (SELECT cp.state, cp.included_sha FROM task_pull_requests cp
              WHERE cp.task_id = #{t}.id AND cp.repository_id = pj.repository_id
              ORDER BY cp.id DESC LIMIT 1) c
            WHERE c.state = 'merged' AND c.included_sha = d.head_sha)
        AND NOT EXISTS (SELECT 1 FROM task_local_branches lb
            WHERE lb.task_id = #{t}.id AND lb.local_repository_id = pj.local_repository_id
              AND lb.state = 'merged' AND lb.head_sha = d.head_sha))
    """
  end

  @waiting_for_sql """
  (SELECT CASE
     WHEN t.status NOT IN ('done', 'verified') THEN 'status'
     WHEN #{active_sql.("t")} THEN 'run'
     WHEN #{code_waiting_sql.("t")} THEN 'merge'
     WHEN t.kind = 'epic' AND EXISTS (SELECT 1 FROM tasks s
       WHERE s.epic_id = t.id AND s.status <> 'cancelled'
         AND (s.status NOT IN ('done', 'verified') OR #{active_sql.("s")}
              OR #{code_waiting_sql.("s")})) THEN 'steps'
   END
   FROM (SELECT ?::bigint AS id, ?::bigint AS project_id, ?::text AS status, ?::text AS kind) t)
  """

  @doc """
  Expands to the fragment of `waiting_for/1` inside a query (a string or
  NULL); `waiting_for_value/1` reads it. Needs `require Helmsman.Links`.
  """
  defmacro waiting_for_sql(id, project_id, status, kind) do
    quote do
      fragment(
        unquote(@waiting_for_sql),
        unquote(id),
        unquote(project_id),
        unquote(status),
        unquote(kind)
      )
    end
  end

  @type type :: Link.type()
  @type waiting_for :: :status | :run | :merge | :steps | nil
  @type link_view :: %{
          type: String.t(),
          direction: String.t(),
          task: String.t(),
          title: String.t(),
          status: String.t(),
          kind: String.t(),
          actor: %{name: String.t(), kind: String.t()},
          created_at: DateTime.t(),
          waiting_for: String.t() | nil
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

  @doc """
  Makes the task `task`, just created by `Helmsman.Tasks.create/3`, depend
  on `prerequisites` (`depends_on`, the links `task → each`).

  The caller holds the workspace graph lock inside the write transaction
  and has checked that every prerequisite is a task of the workspace other
  than `task` and its epic. The new task has no dependents yet, so no
  cycle can form, and a run's reach rule (`:link_tasks`) does not apply:
  the link only makes the creator's own new task wait. After the commit
  `{:links_changed, ident}` goes to the topic of each prerequisite.
  """
  @spec add_dependencies(Scope.t(), Task.t(), [Task.t()]) :: :ok
  def add_dependencies(%Scope{actor: %Actor{id: actor_id}}, %Task{} = task, prerequisites) do
    for %Task{} = prerequisite <- prerequisites do
      insert(task, prerequisite, :depends_on, actor_id)

      Events.after_commit(
        Events.topic(:task, prerequisite.id),
        {:links_changed, prerequisite.ident}
      )
    end

    :ok
  end

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
  #
  # An orchestrating run (`improve-squad-leader-orchestration` decision 8)
  # also locks its squad's rows after the graph lock, before the task rows.
  defp write_locked(scope, op, {from, to}, type) do
    with :ok <- Locks.graph!(scope.workspace.id),
         :ok <- lock_orchestration(scope),
         {:ok, a, b} <- lock_ends(scope.workspace.id, from, to),
         {:ok, orchestration} <- authorize_link(scope, op, a, b, type),
         {:ok, changed?} <- apply_op(op, scope, a, b, type) do
      if changed? and orchestration, do: audit_link(orchestration, op, a, b)
      # Re-read: replacing a step of `from`'s own epic may have moved it
      # (`Helmsman.Tasks.Epics.recompute/3`).
      task = a |> Repo.reload!() |> Tasks.load_detail()
      if changed?, do: notify_links_changed(task, b)
      {:ok, Tasks.detail(task)}
    end
  end

  defp lock_orchestration(scope) do
    if Orchestration.orchestrating?(scope), do: Orchestration.lock!(scope), else: :ok
  end

  # One end must be the run's own task; an orchestrating run may also link
  # two tasks of its scope with `depends_on` (decision 4). `{:ok, nil | ctx}`.
  defp authorize_link(scope, op, a, b, type) do
    case Policy.authorize(scope, :link_tasks, {a, b}) do
      :ok ->
        {:ok, nil}

      {:error, :forbidden} = forbidden ->
        if Orchestration.orchestrating?(scope),
          do: scope |> check_ends(op, [a, b], type) |> Orchestration.emit_error(link_action(op)),
          else: forbidden
    end
  end

  defp link_action(:add), do: :link
  defp link_action(:remove), do: :unlink

  defp check_ends(scope, op, ends, type) do
    Enum.reduce_while(ends, {:ok, nil}, fn task, _acc ->
      case Orchestration.check(scope, task, {:link, type, op}) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        error -> {:halt, error}
      end
    end)
  end

  # The note goes on the `from` end (decision 7).
  defp audit_link(ctx, op, a, b) do
    what =
      case op do
        :add -> "#{a.ident} now depends on #{b.ident}."
        :remove -> "#{a.ident} no longer depends on #{b.ident}."
      end

    Orchestration.emit(link_action(op), :ok)
    Orchestration.audit!(ctx, Repo.reload!(a), what)
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

  # Removing the last unsatisfied dependency releases the deferred runs of
  # `a` (`add-dependency-dispatch` decision 6).
  defp apply_op(:remove, _scope, a, b, type) do
    {count, _} =
      from(l in Link,
        where: l.from_task_id == ^a.id and l.to_task_id == ^b.id and l.type == ^type
      )
      |> Repo.delete_all()

    if count == 1 and type == :depends_on,
      do: :ok = Dependencies.release([a.id])

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
  What the prerequisite `task` is waiting for (designs/07 §3,
  `add-dependency-dispatch` decision 2): the first of these that does not
  hold, or nil when it is satisfied.

    1. `:status` - it is not `done` or `verified`;
    2. `:run` - it has a `claimed`, `running` or `cancelling` run;
    3. `:merge` - its latest delivery (`push_status = 'pushed'` in the
       repository its project is bound to now, greatest `(claimed_at,
       id)`) is not in the base branch: for a GitHub repository its
       current pull request (newest row of that repository) is `merged`
       with `included_sha` equal to the delivery's `head_sha`; for a local
       repository its local branch of that repository is `merged` at that
       `head_sha`. No binding or no delivery: holds;
    4. `:steps` - it is an epic and a step not `cancelled` fails 1-3.

  One query. The single SQL definition (`waiting_for_sql/4`) is shared by
  `satisfied?/1`, `unsatisfied_dependency/1`, `blockers/1`,
  `put_blocked/1` and the links of `for_task/1`.
  """
  @spec waiting_for(Task.t() | pos_integer()) :: waiting_for()
  def waiting_for(%Task{id: id}), do: waiting_for(id)

  def waiting_for(task_id) when is_integer(task_id) do
    from(p in Task,
      as: :prereq,
      where: p.id == ^task_id,
      select: waiting_for_sql(p.id, p.project_id, p.status, p.kind)
    )
    |> Repo.one()
    |> to_waiting_for()
  end

  @doc "Whether the prerequisite `task` is satisfied: `waiting_for/1` is nil."
  @spec satisfied?(Task.t() | pos_integer()) :: boolean()
  def satisfied?(task), do: is_nil(waiting_for(task))

  @doc """
  The condition "the task bound as `binding` has an outgoing `depends_on`
  whose prerequisite is not satisfied" (`waiting_for/1`), as an `EXISTS`
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
      where:
        l.type == :depends_on and
          not is_nil(waiting_for_sql(p.id, p.project_id, p.status, p.kind))
    )
  end

  @doc """
  The unsatisfied prerequisites of each of `task_ids` by internal ID, in
  one query: `%{task_id => [ident]}` (absent: none).
  """
  @spec blockers_of([pos_integer()]) :: %{pos_integer() => [String.t()]}
  def blockers_of([]), do: %{}

  def blockers_of(task_ids) when is_list(task_ids) do
    from([link: l, prereq: p] in unsatisfied_prereqs(),
      where: l.from_task_id in ^task_ids,
      order_by: [asc: l.from_task_id, asc: p.id],
      select: {l.from_task_id, p.ident}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
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

  @doc """
  The IDs of every `depends_on` prerequisite of the task `task_id`,
  satisfied or not, by internal ID, at most `limit`.
  """
  @spec prerequisites(pos_integer(), pos_integer()) :: [String.t()]
  def prerequisites(task_id, limit) when is_integer(task_id) and is_integer(limit) do
    from(l in Link,
      join: p in Task,
      on: p.id == l.to_task_id,
      where: l.from_task_id == ^task_id and l.type == :depends_on,
      order_by: [asc: p.id],
      limit: ^limit,
      select: p.ident
    )
    |> Repo.all()
  end

  @doc "Whether the task `task_id` has an outgoing `depends_on` (no lock)."
  @spec has_dependencies?(pos_integer()) :: boolean()
  def has_dependencies?(task_id) when is_integer(task_id),
    do: Repo.exists?(from(l in Link, where: l.from_task_id == ^task_id and l.type == :depends_on))

  @doc """
  The IDs of the tasks depending (`depends_on`) directly on one of
  `task_ids`, ascending.
  """
  @spec dependents([pos_integer()]) :: [pos_integer()]
  def dependents([]), do: []

  def dependents(task_ids) when is_list(task_ids) do
    from(l in Link,
      where: l.to_task_id in ^task_ids and l.type == :depends_on,
      distinct: true,
      order_by: [asc: l.from_task_id],
      select: l.from_task_id
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
  `kind` (`"task"` / `"epic"`), the `actor` who added it, `created_at`
  and, for an outgoing `depends_on`, `waiting_for` (`waiting_for/1` as a
  string; nil when satisfied and for every other link).
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
      select:
        {l, p, a,
         fragment(
           "CASE WHEN ? = ? AND ? = 'depends_on' THEN ? END",
           l.from_task_id,
           type(^id, :integer),
           l.type,
           waiting_for_sql(p.id, p.project_id, p.status, p.kind)
         )}
    )
    |> Repo.all()
    |> Enum.sort_by(fn {l, p, _a, _w} ->
      {if(l.from_task_id == id, do: 0, else: 1), type_rank(l.type), p.id}
    end)
    |> Enum.map(fn {l, p, a, waiting_for} ->
      %{
        type: Atom.to_string(l.type),
        direction: if(l.from_task_id == id, do: "out", else: "in"),
        task: p.ident,
        title: p.title,
        status: Atom.to_string(p.status),
        kind: Atom.to_string(p.kind),
        actor: %{name: a.name, kind: Atom.to_string(a.kind)},
        created_at: l.inserted_at,
        waiting_for: waiting_for
      }
    end)
  end

  defp type_rank(type), do: Enum.find_index(Link.types(), &(&1 == type))

  @doc "Reads the value of `waiting_for_sql/4` (`waiting_for/1`'s atoms)."
  @spec waiting_for_value(String.t() | nil) :: waiting_for()
  def waiting_for_value(value), do: to_waiting_for(value)

  defp to_waiting_for(nil), do: nil
  defp to_waiting_for("status"), do: :status
  defp to_waiting_for("run"), do: :run
  defp to_waiting_for("merge"), do: :merge
  defp to_waiting_for("steps"), do: :steps

  ## Notifications

  @doc """
  The `Helmsman.Tasks.TransitionSteps` step: `status_changed/3` for the
  transition just written.
  """
  @spec after_transition(Task.t(), TaskEvent.t(), Scope.t()) :: :ok
  def after_transition(%Task{} = task, %TaskEvent{} = event, _scope),
    do: status_changed(task, event.from_status, event.to_status)

  @doc """
  The single entry point for "a prerequisite's status changed"
  (`add-dependency-dispatch` decisions 6, 10), inside the transaction that
  changed it, which holds the workspace graph lock.

  The affected dependents are the tasks depending on `task` and, when it
  is a step, those depending on its epic: their runs deferred by a
  dependency are released when every prerequisite is now satisfied
  (`Dependencies.release/1`).

  After the commit, `{:task_updated, summary}` on the project topic and
  `{:links_changed, ident}` on the task topic of: the tasks depending on
  `task` when moving from `from` to `to` flips its satisfaction (into
  `done` / `verified` with the other conditions of `waiting_for/1`
  holding, or out of them); with a status change of a step whose epic is `done` or
  `verified`, the tasks depending on the epic too.
  """
  @spec status_changed(Task.t(), Task.status() | nil, Task.status()) :: :ok
  def status_changed(%Task{} = task, from, to) do
    direct = dependents([task.id])
    epic = epic_dependents(task, from, to)
    :ok = Dependencies.release(Enum.uniq(direct ++ epic.all))

    notify = if satisfaction_flipped?(task, from, to), do: direct, else: []
    notify_dependents(Enum.uniq(notify ++ epic.notify))
  end

  defp epic_dependents(%Task{epic_id: nil}, _from, _to), do: %{all: [], notify: []}

  defp epic_dependents(%Task{epic_id: epic_id}, from, to) do
    all = dependents([epic_id])

    notify =
      if all != [] and from != to and
           Repo.exists?(from(e in Task, where: e.id == ^epic_id and e.status in ^@satisfied)),
         do: all,
         else: []

    %{all: all, notify: notify}
  end

  # Into `done` / `verified`: flipped when conditions 2-4 hold now. Out of
  # them: they held before unless this transaction changed them too (an
  # epic reopened by a new step), so always (may notify once too often).
  defp satisfaction_flipped?(task, from, to) do
    cond do
      from in @satisfied == to in @satisfied -> false
      to in @satisfied -> rest_satisfied?(task)
      true -> true
    end
  end

  # Conditions 2-4 of `waiting_for/1`, the status read as `done`.
  defp rest_satisfied?(%Task{id: id}) do
    from(p in Task,
      where: p.id == ^id,
      select: waiting_for_sql(p.id, p.project_id, type(^"done", :string), p.kind)
    )
    |> Repo.one()
    |> is_nil()
  end

  @doc """
  Registers, for after the commit, `{:task_updated, summary}` on the
  project topic and `{:links_changed, ident}` on the task topic of each
  task of `task_ids`.
  """
  @spec notify_dependents([pos_integer()]) :: :ok
  def notify_dependents([]), do: :ok

  def notify_dependents(task_ids) do
    from(t in Task, where: t.id in ^task_ids, order_by: [asc: t.id])
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
