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
  alias Helmsman.Dispatch.{Dependencies, LeaderSquad}
  alias Helmsman.Policy
  alias Helmsman.ProviderAccounts.ProviderAccount
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Outcome, TaskGrant}
  alias Helmsman.Squads
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Membership

  @max_instructions_bytes 8192
  @max_rounds 3
  @open_statuses [:new, :in_progress]

  ## Assignment

  @doc """
  Dispatches the task's new assignee (decision 6). Called by
  `Helmsman.Tasks.create/3` and `update/4` after writing the task, in its
  transaction, only when `assignee_id` changed from `prev_assignee_id`;
  the assignee's actor and profile rows are locked `FOR SHARE`, the task
  row `FOR UPDATE`.

  Removes the task's `assign` grants and cancels (`obsolete`) the runs of
  other agents on the task deferred by a dependency
  (`Helmsman.Dispatch.Dependencies.cancel_reassigned/1`); for a managed
  agent the origin may
  trigger (and the trigger chain allows), records a grant, then dispatches
  unless `start?` is false (`:not_started`) or the task is not `new` or
  `in_progress` (`:task_closed`). Returns the outcomes: `[]` for a person,
  an external agent or no assignee, else one.

  A squad (`add-squads` decision 6; its rows locked by `Helmsman.Tasks`
  through `Helmsman.Squads.Dispatch.lock_rows/1`): the origin must be
  allowed to trigger the squad and the leader's trigger chain allow it;
  the grant is recorded for the squad identity (`squad_id` set, the
  origin's chain), and the run is the leader's as the squad.
  """
  @spec on_assignee_change(Scope.t(), Task.t(), pos_integer() | nil, boolean()) ::
          {:ok, [Outcome.t()]}
  def on_assignee_change(%Scope{} = scope, %Task{} = task, _prev_assignee_id, start?) do
    Repo.delete_all(from(g in TaskGrant, where: g.task_id == ^task.id and g.kind == :assign))
    Dependencies.cancel_reassigned(task)
    # `add-autopilots` decision 8: a task an autopilot started settles.
    Helmsman.Autopilots.after_task_changed(task.id)

    case managed_agent(task) do
      nil -> {:ok, assign_squad(scope, task, start?)}
      {agent, profile} -> {:ok, [assign(scope, task, agent, profile, start?)]}
    end
  end

  defp assign_squad(_scope, %Task{assignee_id: nil}, _start?), do: []

  defp assign_squad(scope, %Task{assignee_id: id} = task, start?) do
    case Squads.by_actor_id(id) do
      nil -> []
      squad -> [assign_squad(scope, task, Squads.load(squad), start?)]
    end
  end

  defp assign_squad(scope, task, loaded, start?) do
    origin = Origin.from_scope(scope)

    with :ok <- SquadDispatch.check(origin, loaded, :assign),
         :ok <- squad_chain(origin, loaded, task),
         :ok <- squad_grant(task, loaded, origin),
         :ok <- squad_startable(loaded, task, start?) do
      SquadDispatch.enqueue(origin, loaded, task, %{kind: :assign, instructions: nil},
        check: false
      )
    else
      {:skip, %Outcome{} = outcome} -> outcome
    end
  end

  defp squad_chain(origin, loaded, task) do
    case Runs.check_chain(origin, loaded.leader, task) do
      :ok -> :ok
      {:skip, reason} -> {:skip, SquadDispatch.skipped(loaded, :assign, reason)}
    end
  end

  defp squad_grant(task, loaded, origin) do
    Repo.insert!(%TaskGrant{
      workspace_id: task.workspace_id,
      task_id: task.id,
      agent_id: loaded.actor.id,
      squad_id: loaded.squad.id,
      kind: :assign,
      root_initiator_user_id: origin.initiator_user_id,
      causal_agent_ids: origin.chain,
      granted_by_id: origin.by_actor_id,
      inserted_at: DateTime.utc_now()
    })

    :ok
  end

  defp squad_startable(loaded, task, start?) do
    case startable(task, start?) do
      :ok -> :ok
      {:skip, reason} -> {:skip, SquadDispatch.skipped(loaded, :assign, reason)}
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
  `cancelled` task), `:is_squad` (a squad: assign the task to it or
  mention it instead, `add-squads` decision 4) and `:no_actor`.
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

  # Lock order: actor, profile, task, runtime, run (designs/01 §4). An agent
  # that may lead the squad owning the task (`improve-squad-leader-
  # orchestration` decision 14) has the squad's rows locked first
  # (they include its own); the squad read under the task lock must be the
  # one locked, else the round is taken again from a savepoint.
  defp run_agent_locked(scope, agent_name, task_ident, instructions),
    do: run_agent_round(scope, {agent_name, task_ident, instructions}, 1)

  defp run_agent_round(_scope, _args, round) when round > @max_rounds, do: {:error, :busy}

  defp run_agent_round(scope, {agent_name, task_ident, instructions} = args, round) do
    Repo.query!("SAVEPOINT run_agent")
    guessed = guess_leader_squad(scope.workspace.id, agent_name, task_ident)
    test_hook({:run_agent, round})

    with {:ok, _loaded} <- lock_squad(guessed),
         {:ok, agent, profile} <- lock_agent(scope.workspace.id, agent_name),
         {:ok, task} <- lock_task(scope, task_ident),
         :ok <- open_task(task) do
      squad = LeaderSquad.candidate(task, agent.id)

      if squad == guessed do
        Repo.query!("RELEASE SAVEPOINT run_agent")

        outcome =
          LeaderSquad.enqueue(
            Origin.from_scope(scope),
            %{agent: agent, profile: profile, task: task, lane: :work},
            squad,
            %{kind: :manual, instructions: instructions}
          )

        run = outcome.run_id && Runs.summary(Repo.get!(Runs.Run, outcome.run_id))
        {:ok, %{outcome: outcome, run: run}}
      else
        Repo.query!("ROLLBACK TO SAVEPOINT run_agent")
        run_agent_round(scope, args, round + 1)
      end
    else
      {:error, _reason} = error ->
        Repo.query!("RELEASE SAVEPOINT run_agent")
        error
    end
  end

  # The squad the named agent leads that owns the task, read without locks.
  defp guess_leader_squad(_workspace_id, _agent_name, task_ident) when task_ident in [nil, ""],
    do: nil

  defp guess_leader_squad(workspace_id, agent_name, task_ident) do
    owners = LeaderSquad.guess(workspace_id, task_ident)

    led =
      if owners == [] do
        []
      else
        Repo.all(
          from(s in Squads.Squad,
            join: l in Actor,
            on: l.id == s.leader_agent_id,
            join: a in Actor,
            on: a.id == s.actor_id,
            where:
              s.actor_id in ^owners and l.workspace_id == ^workspace_id and l.name == ^agent_name and
                is_nil(a.disabled_at),
            select: s.actor_id
          )
        )
      end

    Enum.find(owners, &(&1 in led))
  end

  defp lock_squad(nil), do: {:ok, nil}

  defp lock_squad(actor_id) do
    case SquadDispatch.lock_rows(actor_id) do
      nil -> {:ok, nil}
      result -> result
    end
  end

  defp lock_agent(workspace_id, name) do
    actor =
      Repo.one(
        from(a in Actor,
          where:
            a.workspace_id == ^workspace_id and a.name == ^name and a.kind in [:agent, :squad],
          lock: "FOR SHARE"
        )
      )

    with %Actor{} <- actor || {:error, :not_found},
         :ok <- if(actor.kind == :squad, do: {:error, :is_squad}, else: :ok),
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
            left_join: account in ProviderAccount,
            on: account.id == p.provider_account_id,
            where: a.workspace_id == ^workspace_id and a.kind == :agent and is_nil(p.archived_at),
            select: {a, p, r, {d.name, d.protocol_version, account.header_names}}
          )
        )

      role = user_id && member_role(workspace_id, user_id)

      {:ok,
       Map.new(agents, fn {actor, profile, runtime, {daemon_name, protocol, headers}} ->
         {actor.name,
          %{
            result: dispatchable(profile, actor, {user_id, role}, {runtime, protocol, headers}),
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

  defp dispatchable(profile, actor, user, {runtime, protocol, headers}) do
    case TriggerRule.check(profile, actor, user) do
      :ok when is_nil(runtime) -> {:skipped, :no_runtime}
      :ok when not is_nil(runtime.disabled_at) -> {:skipped, :runtime_disabled}
      :ok -> if outdated?(profile, protocol, headers), do: {:skipped, :daemon_outdated}, else: :ok
      {:error, reason} -> {:skipped, reason}
    end
  end

  # A daemon that never reported its version counts as outdated.
  defp outdated?(%AgentProfile{provider_account_id: nil}, _protocol, _headers), do: false

  defp outdated?(_profile, protocol, headers) do
    required =
      if headers in [nil, []],
        do: HelmsmanProtocol.provider_account_version(),
        else: HelmsmanProtocol.provider_account_headers_version()

    (protocol || 0) < required
  end

  defp runtime_view(runtime, daemon_name) do
    %{
      daemon_id: runtime.daemon_id,
      daemon_name: daemon_name,
      provider: runtime.provider,
      status: runtime.status,
      disabled: not is_nil(runtime.disabled_at)
    }
  end

  # Concurrency tests change the task's owner between the guess and the
  # task lock: compiled in the test environment only.
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
