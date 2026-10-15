defmodule Helmsman.Squads.Dispatch do
  @moduledoc """
  Triggers of a squad (`add-squads` decisions 5, 6): every trigger whose
  target is a squad becomes a run of its **leader** as the squad
  (`runs.squad_id`), after checking that the authorization source may
  trigger the squad (`Helmsman.Squads.check_loaded/2`).

  Lock order (decision 3, designs/01 §4): the identity rows of the squad,
  its leader and members `FOR SHARE` (ascending ID), the `squads` row
  `FOR SHARE`, then the profiles of the leader and managed members
  `FOR SHARE`, all before the task row. `lock_rows/1` takes them for a
  squad named by the caller (an assignment); triggers planned under the
  task lock go through `Helmsman.Dispatch.Targets`, which takes the same
  locks for the squads among its candidates.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Outcome}
  alias Helmsman.Squads
  alias Helmsman.Squads.{Member, Squad}
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Membership

  @max_rounds 3

  ## Locking

  @doc """
  Locks the rows of the squad whose identity is `actor_id` for a trigger,
  in the order of the module documentation. Who the leader and members
  are is read before the locks and checked again once the `squads` row is
  held: when they changed, the round is rolled back to a savepoint and
  taken again, at most #{@max_rounds} rounds (then `{:error, :busy}`).
  Returns the squad's `t:Helmsman.Squads.loaded/0`, or nil when
  `actor_id` is not a squad. Must run in a transaction.

  `extra`: other identities locked with them (with their profiles), e.g.
  the current assignee of a task an orchestrating run edits.
  """
  @spec lock_rows(pos_integer(), [pos_integer()]) ::
          {:ok, Squads.loaded()} | {:error, :busy} | nil
  def lock_rows(actor_id, extra \\ []) when is_integer(actor_id) and is_list(extra) do
    case Repo.get_by(Squad, actor_id: actor_id) do
      nil -> nil
      %Squad{id: id} -> round(id, extra, 1, extra)
    end
  end

  defp round(_squad_id, _known, round, _extra) when round > @max_rounds, do: {:error, :busy}

  defp round(squad_id, known, round, extra) do
    Repo.query!("SAVEPOINT squad_rows")
    candidates = Enum.uniq(known ++ squad_actor_ids(squad_id))
    locked = lock_actors(candidates)
    test_hook({:squad_rows, round})
    lock_squads([squad_id])
    current = squad_actor_ids(squad_id)

    if Enum.all?(current, &MapSet.member?(locked, &1)) do
      Repo.query!("RELEASE SAVEPOINT squad_rows")
      lock_profiles(Enum.uniq(current ++ extra))
      {:ok, Squads.load(squad_id)}
    else
      Repo.query!("ROLLBACK TO SAVEPOINT squad_rows")
      round(squad_id, candidates ++ current, round + 1, extra)
    end
  end

  @doc """
  The identities a trigger of the squad `squad_id` depends on, read
  without locking: the squad identity, its leader and members.
  """
  @spec squad_actor_ids(pos_integer()) :: [pos_integer()]
  def squad_actor_ids(squad_id) do
    case Repo.one(
           from(s in Squad, where: s.id == ^squad_id, select: {s.actor_id, s.leader_agent_id})
         ) do
      nil ->
        []

      {actor_id, leader_id} ->
        members =
          Repo.all(from(m in Member, where: m.squad_id == ^squad_id, select: m.actor_id))

        Enum.uniq([actor_id, leader_id | members])
    end
  end

  @doc """
  For the squad identities among `actor_ids`: the identities of their
  leaders and members (`squad_actor_ids/1`), read without locking.
  """
  @spec expand([pos_integer()]) :: [pos_integer()]
  def expand([]), do: []

  def expand(actor_ids) do
    Repo.all(from(s in Squad, where: s.actor_id in ^actor_ids, select: s.id))
    |> Enum.flat_map(&squad_actor_ids/1)
  end

  @doc "Locks the identity rows `ids` `FOR SHARE` by ascending ID; the IDs locked."
  @spec lock_actors([pos_integer()]) :: MapSet.t()
  def lock_actors([]), do: MapSet.new()

  def lock_actors(ids) do
    Repo.all(
      from(a in Actor, where: a.id in ^ids, order_by: a.id, lock: "FOR SHARE", select: a.id)
    )
    |> MapSet.new()
  end

  @doc "Locks the `squads` rows `ids` `FOR SHARE` by ascending ID."
  @spec lock_squads([pos_integer()]) :: :ok
  def lock_squads([]), do: :ok

  def lock_squads(ids) do
    Repo.all(
      from(s in Squad, where: s.id in ^ids, order_by: s.id, lock: "FOR SHARE", select: s.id)
    )

    :ok
  end

  @doc "Locks the profiles of the agents among `actor_ids` `FOR SHARE` by `actor_id`."
  @spec lock_profiles([pos_integer()]) :: :ok
  def lock_profiles([]), do: :ok

  def lock_profiles(actor_ids) do
    Repo.all(
      from(p in AgentProfile,
        where: p.actor_id in ^actor_ids,
        order_by: p.actor_id,
        lock: "FOR SHARE",
        select: p.actor_id
      )
    )

    :ok
  end

  ## Claiming

  @typedoc """
  What the claim check reads of a squad (`Helmsman.Runs.Revalidation`):
  its identity, whether it is disabled, its leader and members.
  """
  @type info :: %{
          actor_id: pos_integer(),
          disabled: boolean(),
          leader_agent_id: pos_integer(),
          member_ids: [pos_integer()]
        }

  @doc """
  The squads the check of `run` reads: the one it runs as and those of
  its `delegated` triggers.
  """
  @spec squad_ids(%{
          required(:squad_id) => pos_integer() | nil,
          required(:triggers) => [map()],
          optional(any()) => any()
        }) :: [pos_integer()]
  def squad_ids(%{squad_id: squad_id, triggers: triggers}) do
    delegated = for %{"kind" => "delegated", "squad_id" => id} <- triggers, is_integer(id), do: id
    [squad_id | delegated] |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  Locks the squads of `squad_ids/1` for the check of `run`, after the
  agent's identity row and before its profile (designs/01 §4): their
  identity rows, then their `squads` rows, `FOR SHARE` by ascending ID.
  `:wait` waits for the locks; `:try` (claiming) uses `SKIP LOCKED` and
  gives `:skip` when a writer holds one. Returns `%{squad_id => info}`
  (a squad gone is absent).
  """
  @spec lock_for_check(map(), :wait | :try) :: {:ok, %{pos_integer() => info()}} | :skip
  def lock_for_check(run, mode) do
    case squad_ids(run) do
      [] -> {:ok, %{}}
      ids -> lock_infos(ids, mode)
    end
  end

  defp lock_infos(ids, mode) do
    squads = Repo.all(from(s in Squad, where: s.id in ^ids, select: {s.id, s.actor_id}))
    actor_ids = squads |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    actors = Repo.all(share(from(a in Actor, where: a.id in ^actor_ids, order_by: a.id), mode))
    rows = Repo.all(share(from(s in Squad, where: s.id in ^ids, order_by: s.id), mode))

    if length(actors) < length(actor_ids) or length(rows) < length(squads) do
      :skip
    else
      members =
        Repo.all(from(m in Member, where: m.squad_id in ^ids, select: {m.squad_id, m.actor_id}))
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      disabled = Map.new(actors, &{&1.id, not is_nil(&1.disabled_at)})

      {:ok,
       Map.new(rows, fn s ->
         {s.id,
          %{
            actor_id: s.actor_id,
            disabled: Map.fetch!(disabled, s.actor_id),
            leader_agent_id: s.leader_agent_id,
            member_ids: Map.get(members, s.id, [])
          }}
       end)}
    end
  end

  defp share(query, :try), do: lock(query, "FOR SHARE SKIP LOCKED")
  defp share(query, :wait), do: lock(query, "FOR SHARE")

  ## Checking and enqueueing

  @doc """
  Whether `origin` may trigger the loaded squad (decision 5), as a
  skipped outcome of its leader when not: `:squad_disabled`,
  `:unauthorized` (with `refused`), `:agent_disabled`, `:agent_archived`.
  """
  @spec check(Origin.t(), Squads.loaded(), Outcome.trigger()) :: :ok | {:skip, Outcome.t()}
  def check(%Origin{initiator_user_id: user_id}, loaded, kind) do
    role = role_of(loaded.squad.workspace_id, user_id)

    case Squads.check_loaded(loaded, {user_id, role}) do
      :ok ->
        :ok

      {:error, :unauthorized, refused} ->
        {:skip, skipped(loaded, kind, :unauthorized, refused)}

      {:error, :not_managed} ->
        {:skip, skipped(loaded, kind, :unauthorized, [loaded.leader.name])}

      {:error, reason} ->
        {:skip, skipped(loaded, kind, reason)}
    end
  end

  @doc "A skipped outcome of the squad's leader."
  @spec skipped(Squads.loaded(), Outcome.trigger(), Outcome.reason(), [String.t()] | nil) ::
          Outcome.t()
  def skipped(loaded, kind, reason, refused \\ nil),
    do: Outcome.squad_skipped(loaded.leader, loaded.actor.name, kind, reason, refused)

  @doc """
  A run of the squad's leader as the squad for `trigger` (as
  `Helmsman.Runs.enqueue/3` takes it), on `task` in `lane`. With
  `check: true` (the default) the origin must first be allowed to
  trigger the squad (`check/3`); otherwise only a disabled squad is
  refused. The trigger entry gets `"squad_id"`.
  """
  @spec enqueue(Origin.t(), Squads.loaded(), Task.t() | nil, Runs.trigger(), keyword()) ::
          Outcome.t()
  def enqueue(%Origin{} = origin, loaded, task, trigger, opts \\ []) do
    checked =
      if Keyword.get(opts, :check, true),
        do: check(origin, loaded, trigger.kind),
        else: disabled(loaded, trigger.kind)

    case checked do
      :ok -> enqueue_leader(origin, loaded, task, trigger, Keyword.get(opts, :lane, :work))
      {:skip, outcome} -> outcome
    end
  end

  defp enqueue_leader(origin, loaded, task, trigger, lane) do
    trigger = Map.update(trigger, :extra, extra(loaded), &Map.merge(&1, extra(loaded)))

    target = %{
      agent: loaded.leader,
      profile: loaded.leader_profile,
      task: task,
      lane: lane,
      squad_id: loaded.squad.id
    }

    {:ok, outcome} = Runs.enqueue(origin, target, trigger)
    Outcome.for_squad(outcome, loaded.actor.name)
  end

  @doc """
  A run of `target.agent` (not necessarily the current leader) as the
  squad `squad_id`, for the triggers that continue a run as the squad
  (an answer to a question written in it, the callback of a task it
  created, a retry, a steering fallback, `delegate_done`): only a
  disabled squad is refused here, the rest is
  `Helmsman.Runs.enqueue/3`; claiming checks that the agent still leads
  the squad. The trigger entry gets `"squad_id"`.
  """
  @spec enqueue_as(Origin.t(), Runs.target(), pos_integer(), Runs.trigger()) :: Outcome.t()
  def enqueue_as(%Origin{} = origin, %{agent: agent} = target, squad_id, trigger) do
    squad_actor =
      Repo.one!(
        from(s in Squad,
          join: a in Actor,
          on: a.id == s.actor_id,
          where: s.id == ^squad_id,
          select: a
        )
      )

    if squad_actor.disabled_at do
      Outcome.squad_skipped(agent, squad_actor.name, trigger.kind, :squad_disabled)
    else
      extra = %{"squad_id" => squad_id}
      trigger = Map.update(trigger, :extra, extra, &Map.merge(&1, extra))
      {:ok, outcome} = Runs.enqueue(origin, Map.put(target, :squad_id, squad_id), trigger)
      Outcome.for_squad(outcome, squad_actor.name)
    end
  end

  defp disabled(%{actor: %Actor{disabled_at: %DateTime{}}} = loaded, kind),
    do: {:skip, skipped(loaded, kind, :squad_disabled)}

  defp disabled(_loaded, _kind), do: :ok

  defp extra(loaded), do: %{"squad_id" => loaded.squad.id}

  # Concurrency tests change the members between the guess and the squad
  # lock: compiled in the test environment only.
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

  defp role_of(_ws, nil), do: nil

  defp role_of(ws, user_id),
    do:
      Repo.one(
        from(m in Membership,
          where: m.workspace_id == ^ws and m.user_id == ^user_id,
          select: m.role
        )
      )
end
