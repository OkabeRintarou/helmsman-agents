defmodule Helmsman.Dispatch do
  @moduledoc """
  The two triggers of this change (designs/13 §2.1): assigning a task to a
  managed agent (`on_assignee_change/4`, called by `Helmsman.Tasks`) and
  starting an agent by hand (`run_agent/4`). Both run inside the write
  transaction that causes them and end in `Helmsman.Runs.enqueue/3`.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.{AgentProfile, TriggerRule}
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Outcome, TaskGrant}
  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Membership

  @max_instructions_bytes 8192
  @open_statuses [:new, :in_progress]

  ## Assignment

  @doc """
  Dispatches the task's new assignee (decision 6). Called by
  `Helmsman.Tasks.create/3` and `update/4` after writing the task, in its
  transaction, only when `assignee_id` changed from `prev_assignee_id`;
  the assignee's actor and profile rows are locked `FOR SHARE`, the task
  row `FOR UPDATE`.

  Removes the task's `assign` grants; for a managed agent the origin may
  trigger (and the trigger chain allows), records a grant, then dispatches
  unless `start?` is false (`:not_started`) or the task is not `new` or
  `in_progress` (`:task_closed`). Returns the outcomes: `[]` for a person,
  an external agent or no assignee, else one.
  """
  @spec on_assignee_change(Scope.t(), Task.t(), pos_integer() | nil, boolean()) ::
          {:ok, [Outcome.t()]}
  def on_assignee_change(%Scope{} = scope, %Task{} = task, _prev_assignee_id, start?) do
    Repo.delete_all(from(g in TaskGrant, where: g.task_id == ^task.id and g.kind == :assign))

    case managed_agent(task) do
      nil -> {:ok, []}
      {agent, profile} -> {:ok, [assign(scope, task, agent, profile, start?)]}
    end
  end

  defp managed_agent(%Task{assignee_id: nil}), do: nil

  defp managed_agent(%Task{assignee_id: id}) do
    Repo.one(
      from(a in Actor,
        join: p in AgentProfile,
        on: p.actor_id == a.id,
        where: a.id == ^id and a.kind == :agent,
        select: {a, p}
      )
    )
  end

  defp assign(scope, task, agent, profile, start?) do
    origin = Origin.from_scope(scope)

    with :ok <- Runs.check_trigger(origin, agent, task),
         :ok <- grant(task, agent, origin),
         :ok <- startable(task, start?) do
      {:ok, outcome} =
        Runs.enqueue(origin, %{agent: agent, profile: profile, task: task, lane: :work}, %{
          kind: :assign,
          instructions: nil
        })

      outcome
    else
      {:skip, reason} -> Outcome.skipped(agent, :assign, reason)
    end
  end

  defp grant(task, agent, origin) do
    Repo.insert!(%TaskGrant{
      workspace_id: task.workspace_id,
      task_id: task.id,
      agent_id: agent.id,
      kind: :assign,
      root_initiator_user_id: origin.initiator_user_id,
      causal_agent_ids: Enum.uniq(origin.chain ++ [agent.id]),
      granted_by_id: origin.by_actor_id,
      inserted_at: DateTime.utc_now()
    })

    :ok
  end

  defp startable(_task, false), do: {:skip, :not_started}
  defp startable(%Task{status: status}, _start?) when status in @open_statuses, do: :ok
  defp startable(_task, _start?), do: {:skip, :task_closed}

  ## Manual

  @doc """
  Starts the managed agent `agent_name` by hand (decision 7), on the task
  `task_ident` or on none, with `instructions` (trimmed, blank is none, at
  most 8 KB, required without a task).

  `{:ok, %{outcome: outcome, run: summary | nil}}` whatever the outcome:
  a trigger that is not dispatched still commits the transaction (with its
  system comment, if any). Errors, which roll back: `:forbidden` (a run
  token, or the role), `:not_found` (agent or task), `:not_managed` (an
  external agent), `:instructions_required`,
  `{:invalid_instructions, :too_long | :not_a_string}`, `:task_closed` (a `verified` or
  `cancelled` task) and `:no_actor`.
  """
  @spec run_agent(Scope.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, %{outcome: Outcome.t(), run: Runs.summary() | nil}} | {:error, term()}
  def run_agent(%Scope{via: :run}, _agent_name, _task_ident, _instructions),
    do: {:error, :forbidden}

  def run_agent(%Scope{actor: nil}, _agent_name, _task_ident, _instructions),
    do: {:error, :no_actor}

  def run_agent(%Scope{} = scope, agent_name, task_ident, instructions)
      when is_binary(agent_name) do
    with {:ok, instructions} <- normalize_instructions(instructions, task_ident) do
      Workspaces.write_transaction(scope, :run_agent, fn scope ->
        run_agent_locked(scope, agent_name, task_ident, instructions)
      end)
    end
  end

  defp normalize_instructions(instructions, task_ident) do
    case trim(instructions) do
      :invalid ->
        {:error, {:invalid_instructions, :not_a_string}}

      nil ->
        if task_ident in [nil, ""], do: {:error, :instructions_required}, else: {:ok, nil}

      text when byte_size(text) > @max_instructions_bytes ->
        {:error, {:invalid_instructions, :too_long}}

      text ->
        {:ok, text}
    end
  end

  defp trim(nil), do: nil

  defp trim(text) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  defp trim(_other), do: :invalid

  # Lock order: actor, profile, task, runtime, run (designs/01 §4).
  defp run_agent_locked(scope, agent_name, task_ident, instructions) do
    with {:ok, agent, profile} <- lock_agent(scope.workspace.id, agent_name),
         {:ok, task} <- lock_task(scope, task_ident),
         :ok <- open_task(task) do
      {:ok, outcome} =
        Runs.enqueue(
          Origin.from_scope(scope),
          %{agent: agent, profile: profile, task: task, lane: :work},
          %{kind: :manual, instructions: instructions}
        )

      run = outcome.run_id && Runs.summary(Repo.get!(Runs.Run, outcome.run_id))
      {:ok, %{outcome: outcome, run: run}}
    end
  end

  defp lock_agent(workspace_id, name) do
    actor =
      Repo.one(
        from(a in Actor,
          where: a.workspace_id == ^workspace_id and a.name == ^name and a.kind == :agent,
          lock: "FOR SHARE"
        )
      )

    with %Actor{} <- actor || {:error, :not_found},
         %AgentProfile{} = profile <-
           Repo.one(from(p in AgentProfile, where: p.actor_id == ^actor.id, lock: "FOR SHARE")) ||
             {:error, :not_managed} do
      {:ok, actor, profile}
    end
  end

  defp lock_task(_scope, ident) when ident in [nil, ""], do: {:ok, nil}
  defp lock_task(scope, ident), do: Tasks.lock(scope, ident)

  defp open_task(%Task{status: status}) when status in [:verified, :cancelled],
    do: {:error, :task_closed}

  defp open_task(_task), do: :ok

  ## Availability

  @typedoc "A managed agent's dispatchability (`availability/1`)."
  @type availability :: %{
          result:
            :ok
            | {:skipped,
               :agent_disabled
               | :unauthorized
               | :no_runtime
               | :runtime_disabled
               | :daemon_outdated},
          runtime:
            %{
              daemon_id: pos_integer(),
              daemon_name: String.t(),
              provider: String.t(),
              status: String.t(),
              disabled: boolean()
            }
            | nil
        }

  @doc """
  Whether `scope.user` could dispatch each managed, unarchived agent of the
  workspace now (`:read_tasks`), by name, with the runtime it is bound to.
  The checks are steps 1–2 of `Helmsman.Runs.enqueue/3`, in order: the
  agent is disabled or the user may not trigger it
  (`Helmsman.Agents.TriggerRule`), it has no runtime, its runtime is
  disabled, then it is bound to a provider account and its runtime's
  daemon last connected with an older protocol than
  `HelmsmanProtocol.provider_account_version/0` (`:daemon_outdated`, which
  claiming would leave queued; `add-provider-accounts` decision 4). An
  offline runtime is `:ok`. Neither the trigger chain nor the
  rate is checked: this is a hint, `enqueue/3` checks again. Two queries,
  whatever the number of agents.
  """
  @spec availability(Scope.t()) :: {:ok, %{String.t() => availability()}} | {:error, :forbidden}
  def availability(%Scope{workspace: %{id: workspace_id}, user: user} = scope) do
    with :ok <- Policy.authorize(scope, :read_tasks) do
      user_id = user && user.id

      agents =
        Repo.all(
          from(a in Actor,
            join: p in AgentProfile,
            on: p.actor_id == a.id and p.workspace_id == a.workspace_id,
            left_join: r in Runtime,
            on: r.id == p.runtime_id,
            left_join: d in Daemon,
            on: d.id == r.daemon_id,
            where: a.workspace_id == ^workspace_id and a.kind == :agent and is_nil(p.archived_at),
            select: {a, p, r, {d.name, d.protocol_version}}
          )
        )

      role = user_id && member_role(workspace_id, user_id)

      {:ok,
       Map.new(agents, fn {actor, profile, runtime, {daemon_name, protocol}} ->
         {actor.name,
          %{
            result: dispatchable(profile, actor, {user_id, role}, {runtime, protocol}),
            runtime: runtime && runtime_view(runtime, daemon_name)
          }}
       end)}
    end
  end

  defp member_role(workspace_id, user_id),
    do:
      Repo.one(
        from(m in Membership,
          where: m.workspace_id == ^workspace_id and m.user_id == ^user_id,
          select: m.role
        )
      )

  defp dispatchable(profile, actor, user, {runtime, protocol}) do
    case TriggerRule.check(profile, actor, user) do
      :ok when is_nil(runtime) -> {:skipped, :no_runtime}
      :ok when not is_nil(runtime.disabled_at) -> {:skipped, :runtime_disabled}
      :ok -> if outdated?(profile, protocol), do: {:skipped, :daemon_outdated}, else: :ok
      {:error, reason} -> {:skipped, reason}
    end
  end

  # A daemon that never reported its version counts as outdated.
  defp outdated?(%AgentProfile{provider_account_id: nil}, _protocol), do: false

  defp outdated?(_profile, protocol),
    do: (protocol || 0) < HelmsmanProtocol.provider_account_version()

  defp runtime_view(runtime, daemon_name) do
    %{
      daemon_id: runtime.daemon_id,
      daemon_name: daemon_name,
      provider: runtime.provider,
      status: runtime.status,
      disabled: not is_nil(runtime.disabled_at)
    }
  end
end
