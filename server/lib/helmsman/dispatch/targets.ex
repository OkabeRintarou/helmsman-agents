defmodule Helmsman.Dispatch.Targets do
  @moduledoc """
  Locks the targets of the triggers a write causes before the task row
  (`add-continuation-triggers` decision 6; designs/01 §4: actor rows, agent
  profile rows, …, task row).

  Who is triggered is only known once the task row is locked (the assignee
  may be changed concurrently, a mentioned name renamed, the last question
  superseded), yet their rows must be locked first. So each round, inside
  the savepoint `dispatch_targets`:

    1. `guess_fun.()` reads the candidate actor IDs without locking; the
       candidates and targets of the previous rounds are added;
    2. the agent actor rows among them are locked `FOR SHARE` by ID, then
       their profile rows `FOR SHARE` by `actor_id`;
    3. `lock_task_fun.()` locks the task row; `targets_fun.(task)` reads,
       under that lock and without writing, the agent actor IDs actually
       triggered and a value the caller needs later;
    4. every target among the rows step 2 returned → `RELEASE SAVEPOINT`;
       otherwise `ROLLBACK TO SAVEPOINT` (which releases the locks of the
       round) and again, at most 3 rounds, then `{:error, :busy}`.

  A squad among the candidates or targets (`add-squads` decision 6) stands
  for itself, its leader and its members: step 2 locks their identity rows
  too, then the `squads` rows `FOR SHARE` (by ID) before the profiles, and
  step 4 requires the leader and members read after the task lock.

  Between the savepoint and the check there are only reads and locks: no
  insert, no `Helmsman.Tx.after_commit/1`, so rolling back to the
  savepoint leaves nothing behind. Works inside an outer transaction too.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Repo
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Squads.Squad

  @max_rounds 3

  @type guess_fun :: (-> [pos_integer()])
  @type lock_task_fun :: (-> {:ok, term()} | {:error, term()})
  @type targets_fun :: (term() -> {[pos_integer()], term()})

  @doc """
  See the module documentation. Returns `{:ok, task, value}` (`task` from
  `lock_task_fun`, `value` from `targets_fun`), the error of
  `lock_task_fun`, or `{:error, :busy}`. Must run in a transaction.
  """
  @spec with_locked(pos_integer(), guess_fun(), lock_task_fun(), targets_fun()) ::
          {:ok, term(), term()} | {:error, term()}
  def with_locked(workspace_id, guess_fun, lock_task_fun, targets_fun)
      when is_function(guess_fun, 0) and is_function(lock_task_fun, 0) and
             is_function(targets_fun, 1) do
    unless Repo.in_transaction?(),
      do: raise("Helmsman.Dispatch.Targets.with_locked/4 must run in a transaction")

    attempt(workspace_id, {guess_fun, lock_task_fun, targets_fun}, [], 1)
  end

  defp attempt(_workspace_id, _funs, _known, round) when round > @max_rounds,
    do: {:error, :busy}

  defp attempt(workspace_id, {guess_fun, lock_task_fun, targets_fun} = funs, known, round) do
    Repo.query!("SAVEPOINT dispatch_targets")
    candidates = Enum.uniq(known ++ guess_fun.())
    locked = lock_agents(workspace_id, candidates)
    test_hook({:dispatch_targets, round})

    case lock_task_fun.() do
      {:ok, task} ->
        {targets, value} = targets_fun.(task)
        targets = Enum.uniq(targets ++ SquadDispatch.expand(targets))

        if Enum.all?(targets, &MapSet.member?(locked, &1)) do
          Repo.query!("RELEASE SAVEPOINT dispatch_targets")
          {:ok, task, value}
        else
          Repo.query!("ROLLBACK TO SAVEPOINT dispatch_targets")
          attempt(workspace_id, funs, Enum.uniq(candidates ++ targets), round + 1)
        end

      {:error, _reason} = error ->
        Repo.query!("RELEASE SAVEPOINT dispatch_targets")
        error
    end
  end

  # The agent and squad rows actually locked, with the leaders and members
  # of the squads: a candidate gone by now is not.
  defp lock_agents(_workspace_id, []), do: MapSet.new()

  defp lock_agents(workspace_id, candidates) do
    squad_rows = SquadDispatch.expand(candidates)

    ids =
      Repo.all(
        from(a in Actor,
          where:
            a.workspace_id == ^workspace_id and
              ((a.id in ^candidates and a.kind in [:agent, :squad]) or a.id in ^squad_rows),
          order_by: a.id,
          lock: "FOR SHARE",
          select: a.id
        )
      )

    SquadDispatch.lock_squads(Repo.all(from(s in Squad, where: s.actor_id in ^ids, select: s.id)))

    if ids != [] do
      Repo.all(
        from(p in AgentProfile,
          where: p.actor_id in ^ids,
          order_by: p.actor_id,
          lock: "FOR SHARE",
          select: p.actor_id
        )
      )
    end

    MapSet.new(ids)
  end

  # Concurrency tests change rows between the guess and the task lock:
  # compiled in the test environment only.
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
