defmodule Helmsman.Runs.Outcome do
  @moduledoc """
  The result of one trigger for one agent (designs/13 §2): the run was
  created (`:queued`), the trigger was added to a queued run (`:merged`),
  or no run was created (`:skipped`, with the `reason`).
  """

  @type result :: :queued | :merged | :skipped
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
  @type t :: %__MODULE__{
          agent: String.t(),
          trigger: :assign | :manual,
          result: result(),
          reason: reason() | nil,
          run_id: pos_integer() | nil
        }

  @enforce_keys [:agent, :trigger, :result]
  defstruct agent: nil, trigger: nil, result: nil, reason: nil, run_id: nil

  @doc "A skipped outcome."
  @spec skipped(String.t(), :assign | :manual, reason()) :: t()
  def skipped(agent, trigger, reason),
    do: %__MODULE__{agent: agent, trigger: trigger, result: :skipped, reason: reason}

  @doc "The external form (MCP): `%{agent, result, reason}`, strings."
  @spec view(t()) :: %{agent: String.t(), result: String.t(), reason: String.t() | nil}
  def view(%__MODULE__{} = outcome) do
    %{
      agent: outcome.agent,
      result: Atom.to_string(outcome.result),
      reason: outcome.reason && Atom.to_string(outcome.reason)
    }
  end
end
