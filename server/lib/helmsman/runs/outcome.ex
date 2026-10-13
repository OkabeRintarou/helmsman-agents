defmodule Helmsman.Runs.Outcome do
  @moduledoc """
  The result of one trigger for one agent (designs/13 §2): the run was
  created (`:queued`), the trigger was added to a queued run (`:merged`),
  the run waits for the task's dependencies (`:deferred`, created or
  merged, with the unsatisfied prerequisites in `blocked_by`;
  `add-dependency-dispatch` decision 4), or no run was created
  (`:skipped`, with the `reason`).
  """

  alias Helmsman.Actors.Actor

  @type trigger :: :assign | :manual | :reopen | :resubmit | :requested | :answer | :mention
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
  @type t :: %__MODULE__{
          agent: String.t(),
          agent_id: pos_integer() | nil,
          trigger: trigger(),
          result: result(),
          reason: reason() | nil,
          blocked_by: [String.t()] | nil,
          run_id: pos_integer() | nil
        }

  @enforce_keys [:agent, :trigger, :result]
  defstruct agent: nil,
            agent_id: nil,
            trigger: nil,
            result: nil,
            reason: nil,
            blocked_by: nil,
            run_id: nil

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
  a `:deferred` outcome also has `blocked_by` (task IDs).
  """
  @spec view(t()) :: %{
          required(:agent) => String.t(),
          required(:trigger) => String.t(),
          required(:result) => String.t(),
          required(:reason) => String.t() | nil,
          optional(:blocked_by) => [String.t()]
        }
  def view(%__MODULE__{} = outcome) do
    view = %{
      agent: outcome.agent,
      trigger: Atom.to_string(outcome.trigger),
      result: Atom.to_string(outcome.result),
      reason: outcome.reason && Atom.to_string(outcome.reason)
    }

    if outcome.result == :deferred,
      do: Map.put(view, :blocked_by, outcome.blocked_by || []),
      else: view
  end

  @doc """
  The stored form, on the feedback that caused the trigger
  (`add-continuation-triggers` decision 10).
  """
  @spec stored(t()) :: map()
  def stored(%__MODULE__{} = outcome) do
    stored = %{
      "agent_id" => outcome.agent_id,
      "trigger" => Atom.to_string(outcome.trigger),
      "result" => Atom.to_string(outcome.result),
      "reason" => outcome.reason && Atom.to_string(outcome.reason),
      "run_id" => outcome.run_id
    }

    if outcome.result == :deferred,
      do: Map.put(stored, "blocked_by", outcome.blocked_by),
      else: stored
  end
end
