defmodule Helmsman.Runs.Outcome do
  @moduledoc """
  The result of one trigger for one agent (designs/13 §2): the run was
  created (`:queued`), the trigger was added to a queued run (`:merged`),
  the run waits for the task's dependencies (`:deferred`, created or
  merged, with the unsatisfied prerequisites in `blocked_by`;
  `add-dependency-dispatch` decision 4), or no run was created
  (`:skipped`, with the `reason`). `steer_run_id`: the trigger waits for
  the run it was sent into (`add-run-steering` decision 5).

  `add-squads` decision 5: a trigger of a squad gives the outcome of its
  leader (`agent`) with the squad's name in `squad`; `refused` lists the
  leader and members the authorization source may not trigger (only with
  the reason `:unauthorized`).
  """

  alias Helmsman.Actors.Actor

  @type trigger ::
          :assign
          | :manual
          | :reopen
          | :resubmit
          | :requested
          | :answer
          | :mention
          | :steer
          | :design
          | :delegated
          | :delegate_done
          | :autopilot
          | :spec_review
          | :spec_reviewed
          | :spec_decided
          | :epic_stalled
  @type result :: :queued | :merged | :deferred | :skipped
  @type reason ::
          :not_started
          | :task_closed
          | :unauthorized
          | :agent_disabled
          | :agent_archived
          | :no_runtime
          | :runtime_disabled
          | :loop_detected
          | :chain_too_long
          | :rate_limited
          | :no_grant
          | :squad_disabled
          | :stall_capped
          | :covered
  @type t :: %__MODULE__{
          agent: String.t(),
          agent_id: pos_integer() | nil,
          trigger: trigger(),
          result: result(),
          reason: reason() | nil,
          blocked_by: [String.t()] | nil,
          run_id: pos_integer() | nil,
          steer_run_id: pos_integer() | nil,
          squad: String.t() | nil,
          refused: [String.t()] | nil
        }

  @enforce_keys [:agent, :trigger, :result]
  defstruct agent: nil,
            agent_id: nil,
            trigger: nil,
            result: nil,
            reason: nil,
            blocked_by: nil,
            run_id: nil,
            steer_run_id: nil,
            squad: nil,
            refused: nil

  @doc "A skipped outcome for `agent`."
  @spec skipped(Actor.t(), trigger(), reason()) :: t()
  def skipped(%Actor{} = agent, trigger, reason) do
    %__MODULE__{
      agent: agent.name,
      agent_id: agent.id,
      trigger: trigger,
      result: :skipped,
      reason: reason
    }
  end

  @doc """
  The external form (MCP): `%{agent, trigger, result, reason}`, strings;
  a `:deferred` outcome also has `blocked_by` (task IDs); a squad's
  outcome `squad` and, when refused, `refused` (names).
  """
  @spec view(t()) :: %{
          required(:agent) => String.t(),
          required(:trigger) => String.t(),
          required(:result) => String.t(),
          required(:reason) => String.t() | nil,
          optional(:blocked_by) => [String.t()],
          optional(:squad) => String.t(),
          optional(:refused) => [String.t()]
        }
  def view(%__MODULE__{} = outcome) do
    view = %{
      agent: outcome.agent,
      trigger: Atom.to_string(outcome.trigger),
      result: Atom.to_string(outcome.result),
      reason: outcome.reason && Atom.to_string(outcome.reason)
    }

    view =
      if outcome.result == :deferred,
        do: Map.put(view, :blocked_by, outcome.blocked_by || []),
        else: view

    view
    |> put_set(:squad, outcome.squad)
    |> put_set(:refused, outcome.refused)
  end

  defp put_set(map, _key, nil), do: map
  defp put_set(map, key, value), do: Map.put(map, key, value)

  @doc """
  The stored form, on the feedback that caused the trigger
  (`add-continuation-triggers` decision 10); `steer_run_id` only when set.
  """
  @spec stored(t()) :: map()
  def stored(%__MODULE__{steer_run_id: id} = outcome) when is_integer(id),
    do: outcome |> Map.put(:steer_run_id, nil) |> stored() |> Map.put("steer_run_id", id)

  def stored(%__MODULE__{} = outcome) do
    stored = %{
      "agent_id" => outcome.agent_id,
      "trigger" => Atom.to_string(outcome.trigger),
      "result" => Atom.to_string(outcome.result),
      "reason" => outcome.reason && Atom.to_string(outcome.reason),
      "run_id" => outcome.run_id
    }

    stored =
      if outcome.result == :deferred,
        do: Map.put(stored, "blocked_by", outcome.blocked_by),
        else: stored

    stored
    |> put_set("squad", outcome.squad)
    |> put_set("refused", outcome.refused)
  end

  @doc """
  The outcome of a trigger of the squad `squad` (its name) for its leader:
  `outcome` with the squad set.
  """
  @spec for_squad(t(), String.t()) :: t()
  def for_squad(%__MODULE__{} = outcome, squad) when is_binary(squad),
    do: %{outcome | squad: squad}

  @doc """
  A skipped outcome of a trigger of the squad `squad` (its name) for its
  leader `leader`; `refused` with `:unauthorized`.
  """
  @spec squad_skipped(Actor.t(), String.t(), trigger(), reason(), [String.t()] | nil) :: t()
  def squad_skipped(%Actor{} = leader, squad, trigger, reason, refused \\ nil),
    do: %{skipped(leader, trigger, reason) | squad: squad, refused: refused}
end
