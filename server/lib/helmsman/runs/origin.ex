defmodule Helmsman.Runs.Origin do
  @moduledoc """
  The authorization source of a trigger (designs/13 §2.2): who caused it
  (`by_actor_id`), on whose behalf (`initiator_user_id`) and the agents
  the trigger chain went through before it (`chain`).

  A person (web, or an `hm_` token, external agents included) is the
  initiator, with an empty chain. A managed agent in a run passes on its
  run's initiator and causal chain, never its owner.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Runs.Run

  @type t :: %__MODULE__{
          by_actor_id: pos_integer(),
          initiator_user_id: pos_integer(),
          chain: [pos_integer()]
        }

  @enforce_keys [:by_actor_id, :initiator_user_id]
  defstruct by_actor_id: nil, initiator_user_id: nil, chain: []

  @doc "The origin of a trigger caused by `scope`."
  @spec from_scope(Scope.t()) :: t()
  def from_scope(%Scope{via: :run, run: %Run{} = run, actor: %Actor{id: actor_id}}) do
    %__MODULE__{
      by_actor_id: actor_id,
      initiator_user_id: run.root_initiator_user_id,
      chain: run.causal_agent_ids
    }
  end

  def from_scope(%Scope{via: via, user: %{id: user_id}, actor: %Actor{id: actor_id}})
      when via in [:web, :mcp, :api] do
    %__MODULE__{by_actor_id: actor_id, initiator_user_id: user_id, chain: []}
  end
end
