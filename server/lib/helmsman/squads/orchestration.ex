defmodule Helmsman.Squads.Orchestration do
  @moduledoc """
  A squad leader's orchestration of the work it leads
  (`improve-squad-leader-orchestration` decisions 1–8).

  A run as the squad S (`runs.squad_id`) on the task T has an
  orchestration root (`root/2`), the first of: T when its assignee is S;
  T's epic when the epic's assignee is S; the root R recorded on T's
  `requested` grant of S (non-nil, decision 2) when R's assignee is still
  S; none otherwise. The scope of a root R (`scope_ids/2`) is R's current
  steps (R an epic) and the tasks whose `requested` grant of S records R;
  R itself is never a target. A root is only recorded on a task that
  belongs to no epic, and cleared in the transaction that changes the
  task's epic (`clear_root!/1`), so a detached step leaves the scope.

  A run with the `orchestrate` capability (`Helmsman.Runs.capabilities/4`)
  may, on a task of its scope other than its own, only assign it to a
  member, start its assignee (`Helmsman.Squads.start_task/3`) and add or
  remove `depends_on` links. `check/3` decides it under the locks of
  decision 8: the squad's rows (`lock!/1`) are locked before the task
  rows, and an epic's steps and its assignee only change under the graph
  lock, so the scope is stable for the transaction. Every successful
  write leaves a system note on the target (`audit!/4`, decision 7).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.{Feedback, Locks, Policy, Repo}
  alias Helmsman.Runs.{Outcome, Run, TaskGrant}
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Squads.{Member, Squad}
  alias Helmsman.Tasks.Task

  @fields ["assignee", "start"]
  @max_quote_bytes 1024

  @type ctx :: %{
          squad: Squad.t(),
          squad_actor: Actor.t(),
          leader: Actor.t(),
          run: Run.t(),
          run_task: Task.t() | nil,
          root: Task.t() | nil
        }

  @type reason ::
          {:orchestration, :outside, String.t(), String.t() | nil}
          | {:orchestration, :root, String.t()}
          | {:orchestration, :fields, [String.t()]}
          | {:orchestration, :outside_assignee, String.t(), String.t()}
          | {:orchestration, :not_member, String.t(), String.t()}
          | {:orchestration, :no_assignee, String.t()}
          | {:orchestration, :person_assignee, String.t(), String.t()}
          | {:orchestration, :not_managed, String.t(), String.t()}
          | {:orchestration, :link_type}
          | {:orchestration, :not_leader | :squad_disabled, String.t()}

  ## Root and scope

  @doc "The orchestration root of a run as the squad `squad_id` on `task`; see the module documentation."
  @spec root(Task.t() | nil, pos_integer() | nil) :: Task.t() | nil
  def root(nil, _squad_id), do: nil
  def root(_task, nil), do: nil

  def root(%Task{} = task, squad_id) do
    case Repo.one(from(s in Squad, where: s.id == ^squad_id, select: s.actor_id)) do
      nil -> nil
      squad_actor_id -> root_of(task, squad_id, squad_actor_id)
    end
  end

  defp root_of(%Task{assignee_id: id} = task, _squad_id, id), do: task

  defp root_of(task, squad_id, squad_actor_id),
    do: owned_epic(task, squad_actor_id) || granted_root(task, squad_id, squad_actor_id)

  defp owned_epic(%Task{epic_id: nil}, _squad_actor_id), do: nil

  defp owned_epic(%Task{epic_id: epic_id}, squad_actor_id),
    do: Repo.one(from(t in Task, where: t.id == ^epic_id and t.assignee_id == ^squad_actor_id))

  defp granted_root(%Task{id: task_id}, squad_id, squad_actor_id) do
    Repo.one(
      from(g in TaskGrant,
        join: r in Task,
        on: r.id == g.root_task_id,
        where:
          g.task_id == ^task_id and g.kind == :requested and g.squad_id == ^squad_id and
            r.assignee_id == ^squad_actor_id,
        order_by: [asc: g.id],
        limit: 1,
        select: r
      )
    )
  end

  @doc """
  The IDs of the tasks in the scope of `root` for the squad `squad_id`
  (two queries), `root` itself left out.
  """
  @spec scope_ids(Task.t(), pos_integer()) :: MapSet.t(pos_integer())
  def scope_ids(%Task{} = root, squad_id) do
    steps =
      if root.kind == :epic,
        do: Repo.all(from(t in Task, where: t.epic_id == ^root.id, select: t.id)),
        else: []

    granted =
      Repo.all(
        from(g in TaskGrant,
          where: g.kind == :requested and g.squad_id == ^squad_id and g.root_task_id == ^root.id,
          select: g.task_id
        )
      )

    (steps ++ granted) |> MapSet.new() |> MapSet.delete(root.id)
  end

  @doc """
  The root to record on the `requested` grant of `task`, just created in
  `scope`: the run's root when the run is as a squad and `task` belongs
  to no epic; nil otherwise.
  """
  @spec root_for_new(Scope.t(), Task.t()) :: pos_integer() | nil
  def root_for_new(
        %Scope{via: :run, run: %Run{squad_id: squad_id, task_id: run_task_id}},
        %Task{epic_id: nil}
      )
      when is_integer(squad_id) and is_integer(run_task_id) do
    case root(Repo.get(Task, run_task_id), squad_id) do
      %Task{id: id} -> id
      nil -> nil
    end
  end

  def root_for_new(_scope, _task), do: nil

  @doc """
  Clears the root recorded on the `requested` grants of `task`, whose epic
  just changed (decision 2); the grants themselves stay.
  """
  @spec clear_root!(Task.t()) :: :ok
  def clear_root!(%Task{id: id}) do
    Repo.update_all(
      from(g in TaskGrant, where: g.task_id == ^id and not is_nil(g.root_task_id)),
      set: [root_task_id: nil]
    )

    :ok
  end

  ## Writes

  @doc "Whether `scope` is a run with the `orchestrate` capability."
  @spec orchestrating?(Scope.t()) :: boolean()
  def orchestrating?(%Scope{via: :run, run: %Run{squad_id: squad_id, capabilities: caps}})
      when is_integer(squad_id),
      do: "orchestrate" in caps

  def orchestrating?(_scope), do: false

  @doc """
  Before any task row: the workspace graph lock and the rows of the run's
  squad (`Helmsman.Squads.Dispatch.lock_rows/1`: identity rows, the
  `squads` row, the profiles), so that the leader, the members and the
  scope stay as checked (decision 8). Only for an orchestrating run.
  """
  @spec lock!(Scope.t()) :: :ok | {:error, :busy}
  def lock!(%Scope{run: %Run{squad_id: squad_id}} = scope) do
    Locks.graph!(scope.workspace.id)

    case Repo.one(from(s in Squad, where: s.id == ^squad_id, select: s.actor_id)) do
      nil ->
        :ok

      actor_id ->
        case SquadDispatch.lock_rows(actor_id) do
          {:error, :busy} = busy -> busy
          _locked -> :ok
        end
    end
  end

  @doc """
  Checks that the orchestrating run of `scope` may do `op` on `target`
  (its task row locked, after `lock!/1`):

    * `{:update, attrs, new_assignee}` — `attrs` only `assignee` / `start`;
      `new_assignee` (the resolved id, nil, or `:keep`) nil or a member
      other than the leader; the current assignee nil, the squad, its
      leader, a member, or a disabled or archived managed agent;
    * `:start` — only the scope (the assignee rules are `start_task`'s);
    * `{:link, type, :add | :remove}` — `depends_on` only.

  The squad must be enabled and led by the run's agent, `target` in the
  scope and not the root. Returns the context for `audit!/4`.
  """
  @spec check(Scope.t(), Task.t(), term()) :: {:ok, ctx()} | {:error, reason() | :forbidden}
  def check(%Scope{} = scope, %Task{} = target, op) do
    with {:ok, ctx} <- context(scope),
         :ok <- in_scope(scope, ctx, target),
         :ok <- check_op(ctx, target, op),
         do: {:ok, ctx}
  end

  @doc "The context of an orchestrating run under the locks: its squad, leader, task and root."
  @spec context(Scope.t()) :: {:ok, ctx()} | {:error, reason() | :forbidden}
  def context(%Scope{run: %Run{} = run} = scope) do
    with true <- orchestrating?(scope) || {:error, :forbidden},
         %Squad{} = squad <- Repo.get(Squad, run.squad_id) || {:error, :forbidden} do
      squad_actor = Repo.get!(Actor, squad.actor_id)
      run_task = run.task_id && Repo.get(Task, run.task_id)

      cond do
        squad_actor.disabled_at ->
          {:error, {:orchestration, :squad_disabled, squad_actor.name}}

        squad.leader_agent_id != run.agent_id ->
          {:error, {:orchestration, :not_leader, squad_actor.name}}

        true ->
          {:ok,
           %{
             squad: squad,
             squad_actor: squad_actor,
             leader: Repo.get!(Actor, squad.leader_agent_id),
             run: run,
             run_task: run_task,
             root: root(run_task, squad.id)
           }}
      end
    end
  end

  def context(_scope), do: {:error, :forbidden}

  defp in_scope(_scope, %{root: nil}, target),
    do: {:error, {:orchestration, :outside, target.ident, nil}}

  defp in_scope(_scope, %{root: %Task{id: id}}, %Task{id: id, ident: ident}),
    do: {:error, {:orchestration, :root, ident}}

  defp in_scope(scope, ctx, target) do
    covered = MapSet.member?(scope_ids(ctx.root, ctx.squad.id), target.id)

    case Policy.authorize(scope, :orchestrate_task, %{covered: covered, root?: false}) do
      :ok when covered ->
        :ok

      _refused when not covered ->
        {:error, {:orchestration, :outside, target.ident, ctx.root.ident}}

      refused ->
        refused
    end
  end

  defp check_op(ctx, target, {:update, attrs, new_assignee}) do
    with :ok <- check_fields(attrs) do
      check_assignees(ctx, target, new_assignee)
    end
  end

  defp check_op(_ctx, _target, :start), do: :ok
  defp check_op(_ctx, _target, {:link, :depends_on, _op}), do: :ok
  defp check_op(_ctx, _target, {:link, _type, _op}), do: {:error, {:orchestration, :link_type}}

  defp check_fields(attrs) do
    if Enum.all?(Map.keys(attrs), &(to_string(&1) in @fields)),
      do: :ok,
      else: {:error, {:orchestration, :fields, @fields}}
  end

  # No change of assignee: nothing to check (and nothing happens).
  defp check_assignees(_ctx, _target, :keep), do: :ok
  defp check_assignees(_ctx, %Task{assignee_id: same}, same), do: :ok

  defp check_assignees(ctx, target, new_id) do
    members = member_ids(ctx.squad)

    cond do
      not is_nil(new_id) and new_id not in members ->
        {:error, {:orchestration, :not_member, name(new_id), ctx.squad_actor.name}}

      not current_ok?(ctx, target.assignee_id, members) ->
        {:error, {:orchestration, :outside_assignee, target.ident, name(target.assignee_id)}}

      true ->
        :ok
    end
  end

  defp current_ok?(_ctx, nil, _members), do: true

  defp current_ok?(ctx, id, members) do
    id in [ctx.squad_actor.id, ctx.squad.leader_agent_id | members] or retired_agent?(id)
  end

  # A disabled or archived managed agent: its work may be handed over.
  defp retired_agent?(id) do
    Repo.exists?(
      from(a in Actor,
        join: p in AgentProfile,
        on: p.actor_id == a.id,
        where: a.id == ^id and (not is_nil(a.disabled_at) or not is_nil(p.archived_at))
      )
    )
  end

  @doc "The identity IDs of the squad's members (never the leader)."
  @spec member_ids(Squad.t()) :: [pos_integer()]
  def member_ids(%Squad{id: id}),
    do: Repo.all(from(m in Member, where: m.squad_id == ^id, select: m.actor_id))

  defp name(id), do: Repo.one(from(a in Actor, where: a.id == ^id, select: a.name))

  ## Audit (decision 7)

  @doc """
  Writes the system note of an orchestration write on `task` (its row
  locked): `Orchestration by <leader> (squad <S>, run <n> on <T>, root
  <R>): <what>`, with the trigger outcomes as its dispatch. Returns the
  task read again.
  """
  @spec audit!(ctx(), Task.t(), String.t(), [Outcome.t()]) :: Task.t()
  def audit!(ctx, %Task{} = task, what, outcomes \\ []) do
    system =
      Repo.one!(
        from(a in Actor, where: a.workspace_id == ^task.workspace_id and a.kind == :system)
      )

    content =
      "Orchestration by #{ctx.leader.name} (squad #{ctx.squad_actor.name}, run #{ctx.run.id} " <>
        "on #{ctx.run_task && ctx.run_task.ident}, root #{ctx.root.ident}): " <> what

    {:ok, {entry, task}} =
      Feedback.insert_locked(task, %Scope{actor: system}, %{kind: :comment, content: content},
        notify: false,
        mentions: []
      )

    {_entry, task} = Feedback.finish_locked(task, entry, outcomes)
    task
  end

  @doc "The quoted instructions of a start, at most #{@max_quote_bytes} bytes."
  @spec quote(String.t() | nil) :: String.t()
  def quote(nil), do: ""

  def quote(text) do
    {kept, cut?} = prefix(text, @max_quote_bytes)
    lines = kept |> String.split(~r/\r?\n/) |> Enum.map_join("\n", &("> " <> &1))
    "\n" <> if(cut?, do: lines <> " …", else: lines)
  end

  defp prefix(text, max) when byte_size(text) <= max, do: {text, false}

  defp prefix(text, max) do
    cut = binary_part(text, 0, max)
    {valid(cut), true}
  end

  defp valid(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid(binary_part(binary, 0, byte_size(binary) - 1))
  end

  ## Telemetry (decision 17)

  @doc "Emits the event of `result` when it is an error; returns `result`."
  @spec emit_error(term(), :assign | :start | :link | :unlink) :: term()
  def emit_error({:error, _} = result, action) do
    emit(action, result)
    result
  end

  def emit_error(result, _action), do: result

  @doc "Emits `[:helmsman, :orchestration, :write]` for `action` and its result."
  @spec emit(:assign | :start | :link | :unlink | nil, term()) :: :ok
  def emit(nil, _result), do: :ok

  def emit(action, result) do
    result =
      case result do
        {:ok, _} -> :ok
        :ok -> :ok
        {:error, {:orchestration, reason, _}} -> reason
        {:error, {:orchestration, reason, _, _}} -> reason
        {:error, {:orchestration, reason}} -> reason
        {:error, reason} when is_atom(reason) -> reason
        _other -> :error
      end

    :telemetry.execute([:helmsman, :orchestration, :write], %{count: 1}, %{
      action: action,
      result: result
    })
  end
end
