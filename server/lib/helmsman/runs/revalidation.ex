defmodule Helmsman.Runs.Revalidation do
  @moduledoc """
  Whether a claimed or claimable run is still valid (designs/13 §4.1–4.2,
  `add-run-lifecycle` decision 4). A pure function of the run and of the
  rows the caller locked (decision 24); it never reads the database.

  A run is obsolete when its agent is disabled or archived, its runtime is
  disabled or no longer the agent's, or a `work` run's task is
  `cancelled` or `verified`. A run as a squad leader (`add-squads`
  decision 10) is obsolete when the squad is disabled or gone
  (`:squad_disabled`) or its agent no longer leads it (`:not_leader`).

  Then the triggers are dropped one by one (`add-squads` decision 10):

    1. those settled by steering (below);
    2. those bound to an assignee (`Helmsman.Runs.Triggers.bound_assignee/2`)
       that is no longer the task's assignee, and the `delegated` ones
       whose squad is disabled or gone or no longer has the run's agent as
       a member;
    3. those whose authorization source (`initiator_user_id`) may no
       longer trigger the agent, checked like
       `Helmsman.Agents.trigger_check/3` on the locked membership rows (a
       run as a squad leader checks the leader only). A run without any
       such trigger is checked with its `root_initiator_user_id`.

  Between 2 and 3, a trigger with a review request (`"spec_request"`,
  `add-spec-workflow` decision 10) whose request is no longer
  `requested` (`spec_requests: %{number => status}`, read by the caller)
  is dropped; nothing else left is `{:obsolete, :spec_settled}`. So are
  the `epic_stalled` triggers when the epic is no longer stalled
  (`epic_stalled: :not_stalled`, `improve-squad-leader-orchestration`
  decision 10; nothing else left: `{:obsolete, :epic_progressed}`).

  When the earliest trigger is dropped, the next one's source and chain
  are used (`derive/2`). Nothing left but neutral markers: the step that
  dropped the last ones decides — authorization `:unauthorized`, the
  others obsolete (`:steered`, `:reassigned`).

  First of all, the triggers settled by steering are removed
  (`Helmsman.Runs.Steering.prune/2`, `add-run-steering` decision 7) with
  the facts the caller read into `steers` (`Steering.facts/1`, after it
  holds the task lock and saw no active run on the task); nothing but
  neutral markers left is `{:obsolete, :steered}`, some removed is
  `{:pruned, …}` unless another check fails.

  A design run whose conversation is no longer open, or whose turn it no
  longer is (`design: :ended`, read by the caller), is obsolete
  (`add-agent-conversation` decision 10). So is a run-only autopilot run
  whose record is gone or no longer `started` (`autopilot: :ended`,
  `add-autopilots` decision 11).
  """

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs.{Run, Steering, Triggers}
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Membership

  @type locked :: %{
          required(:members) => %{pos_integer() => Membership.role()},
          required(:agent) => Actor.t(),
          optional(:squads) => %{pos_integer() => SquadDispatch.info()},
          required(:profile) => AgentProfile.t() | nil,
          required(:task) => Task.t() | nil,
          required(:runtime) => Runtime.t() | nil,
          optional(:steers) => Steering.facts(),
          optional(:design) => :current | :ended | nil,
          optional(:autopilot) => :current | :ended | nil,
          optional(:spec_requests) => %{pos_integer() => atom()},
          optional(:epic_stalled) => :stalled | :not_stalled | nil
        }
  @type obsolete_why ::
          :agent_disabled
          | :agent_archived
          | :runtime_disabled
          | :runtime_changed
          | :task_closed
          | :reassigned
          | :steered
          | :design_ended
          | :squad_disabled
          | :not_leader
          | :autopilot_ended
          | :spec_settled
          | :epic_progressed
  @type changes :: %{
          triggers: [map()],
          root_initiator_user_id: pos_integer(),
          causal_agent_ids: [pos_integer()]
        }
  @type result ::
          :ok
          | {:obsolete, obsolete_why()}
          | :unauthorized
          | {:pruned, changes()}

  @doc "Checks `run` against the `locked` rows; see the module documentation."
  @spec check(Run.t(), locked()) :: result()
  def check(%Run{} = run, locked) do
    case Steering.prune(run, Map.get(locked, :steers, %{})) do
      :unchanged ->
        check_valid(run, locked)

      {:obsolete, _run_ids} ->
        {:obsolete, :steered}

      {:pruned, changes} ->
        case check_valid(struct!(run, changes), locked) do
          :ok -> {:pruned, changes}
          result -> result
        end
    end
  end

  defp check_valid(run, locked) do
    with nil <- obsolete(run, locked),
         {:ok, kept} <- drop_unbound(run, locked),
         {:ok, kept} <- drop_settled_specs(kept, locked),
         {:ok, kept} <- drop_epic_stalled(kept, locked) do
      authorize_kept(run, kept, locked)
    else
      {:obsolete, why} -> {:obsolete, why}
      why -> {:obsolete, why}
    end
  end

  defp authorize_kept(%Run{triggers: kept} = run, kept, locked), do: authorization(run, locked)

  defp authorize_kept(run, kept, locked) do
    changes = derive(run, kept)

    case authorization(struct!(run, changes), locked) do
      :ok -> {:pruned, changes}
      other -> other
    end
  end

  # Step 2: the triggers bound to an assignee that is no longer the task's.
  # A run without a task keeps them all.
  defp drop_unbound(%Run{task_id: nil} = run, _locked), do: {:ok, run.triggers}
  defp drop_unbound(run, %{task: nil}), do: {:ok, run.triggers}

  defp drop_unbound(run, %{task: task} = locked) do
    squads = Map.get(locked, :squads, %{})

    kept =
      Enum.filter(run.triggers, &(Triggers.neutral?(&1) or bound_valid?(&1, run, task, squads)))

    left? = Enum.any?(kept, &(not Triggers.neutral?(&1)))
    had? = Enum.any?(run.triggers, &(not Triggers.neutral?(&1)))

    if had? and not left?, do: {:obsolete, :reassigned}, else: {:ok, kept}
  end

  # The triggers whose review request was settled meanwhile.
  # `improve-squad-leader-orchestration` decision 10: `epic_stalled`
  # triggers of an epic no longer stalled (`epic_stalled: :not_stalled`,
  # read by the caller, this run left out).
  defp drop_epic_stalled(kept, %{epic_stalled: :not_stalled}) do
    left = Enum.reject(kept, &(&1["kind"] == "epic_stalled"))

    if Enum.any?(kept, &(not Triggers.neutral?(&1))) and
         not Enum.any?(left, &(not Triggers.neutral?(&1))),
       do: :epic_progressed,
       else: {:ok, left}
  end

  defp drop_epic_stalled(kept, _locked), do: {:ok, kept}

  defp drop_settled_specs(kept, locked) do
    states = Map.get(locked, :spec_requests, %{})

    left =
      Enum.reject(kept, fn trigger ->
        n = trigger["spec_request"]
        is_integer(n) and Map.get(states, n, :requested) != :requested
      end)

    if Enum.any?(kept, &(not Triggers.neutral?(&1))) and
         not Enum.any?(left, &(not Triggers.neutral?(&1))),
       do: :spec_settled,
       else: {:ok, left}
  end

  defp bound_valid?(trigger, run, task, squads) do
    case Triggers.bound_assignee(trigger, run) do
      nil ->
        true

      {:actor, id} ->
        task.assignee_id == id

      {:squad, squad_id} ->
        case squads[squad_id] do
          nil ->
            false

          squad ->
            task.assignee_id == squad.actor_id and
              (trigger["kind"] != "delegated" or
                 (not squad.disabled and run.agent_id in squad.member_ids))
        end
    end
  end

  @doc """
  The changes of a run whose triggers become `kept` (`add-run-lifecycle`
  decision 4): the earliest kept trigger with an authorization source
  gives `root_initiator_user_id`, the causal chain is the union of the
  kept sources' chains and the agent. Without any source left, both stay.
  """
  @spec derive(Run.t(), [map()]) :: changes()
  def derive(%Run{} = run, kept) do
    case Enum.filter(kept, &source?/1) do
      [] ->
        %{
          triggers: kept,
          root_initiator_user_id: run.root_initiator_user_id,
          causal_agent_ids: run.causal_agent_ids
        }

      [first | _] = sources ->
        causal =
          sources
          |> Enum.flat_map(&(&1["causal_agent_ids"] || []))
          |> Enum.concat([run.agent_id])
          |> Enum.uniq()
          |> Enum.sort()

        %{
          triggers: kept,
          root_initiator_user_id: first["initiator_user_id"],
          causal_agent_ids: causal
        }
    end
  end

  defp obsolete(run, %{agent: agent, profile: profile, runtime: runtime, task: task} = locked) do
    agent_obsolete(agent, profile) || runtime_obsolete(run, profile, runtime) ||
      task_obsolete(run, task) || design_obsolete(locked) || squad_obsolete(run, locked) ||
      autopilot_obsolete(locked)
  end

  # `add-autopilots` decision 11: a run-only autopilot run is valid only
  # while its record exists and is `started`.
  defp autopilot_obsolete(%{autopilot: :ended}), do: :autopilot_ended
  defp autopilot_obsolete(_locked), do: nil

  # `add-squads` decision 10: a run as a squad leader.
  defp squad_obsolete(%Run{squad_id: nil}, _locked), do: nil

  defp squad_obsolete(%Run{squad_id: squad_id, agent_id: agent_id}, locked) do
    case Map.get(locked, :squads, %{})[squad_id] do
      nil -> :squad_disabled
      %{disabled: true} -> :squad_disabled
      %{leader_agent_id: ^agent_id} -> nil
      _other -> :not_leader
    end
  end

  # `add-agent-conversation` decision 10: a design run is valid only while
  # it is the turn of an open conversation (`Helmsman.AgentDesigns.turn_state/1`).
  defp design_obsolete(%{design: :ended}), do: :design_ended
  defp design_obsolete(_locked), do: nil

  defp agent_obsolete(agent, profile) do
    cond do
      not is_nil(agent.disabled_at) -> :agent_disabled
      is_nil(profile) or not is_nil(profile.archived_at) -> :agent_archived
      true -> nil
    end
  end

  defp runtime_obsolete(run, profile, runtime) do
    cond do
      is_nil(runtime) or not is_nil(runtime.disabled_at) -> :runtime_disabled
      run.runtime_id != profile.runtime_id -> :runtime_changed
      true -> nil
    end
  end

  defp task_obsolete(run, task) do
    if closed_work?(run, task), do: :task_closed
  end

  defp closed_work?(%Run{lane: :work}, %Task{status: status}),
    do: status in [:cancelled, :verified]

  defp closed_work?(_run, _task), do: false

  defp authorization(run, locked) do
    sources = Enum.filter(run.triggers, &source?/1)

    if sources == [] do
      if allowed?(run.root_initiator_user_id, locked), do: :ok, else: :unauthorized
    else
      prune(run, locked)
    end
  end

  defp prune(run, locked) do
    kept =
      Enum.filter(run.triggers, &(not source?(&1) or allowed?(&1["initiator_user_id"], locked)))

    case Enum.filter(kept, &source?/1) do
      [] ->
        :unauthorized

      _sources when length(kept) == length(run.triggers) ->
        :ok

      _sources ->
        {:pruned, derive(run, kept)}
    end
  end

  defp source?(%{"initiator_user_id" => id}) when is_integer(id), do: true
  defp source?(_trigger), do: false

  defp allowed?(user_id, %{members: members, agent: agent, profile: profile}),
    do: Agents.may_trigger?(profile, agent, user_id, Map.get(members, user_id))
end
