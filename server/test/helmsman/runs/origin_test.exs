defmodule Helmsman.Runs.OriginTest do
  use ExUnit.Case, async: true

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Runs.{Origin, Run}

  @user %User{id: 10}
  @human %Actor{id: 100, kind: :human, user_id: 10}
  @external %Actor{id: 200, kind: :agent, owner_id: 10}
  @managed %Actor{id: 300, kind: :agent, owner_id: 10}

  test "web: the person, no chain" do
    scope = %Scope{user: @user, actor: @human, via: :web}
    assert Origin.from_scope(scope) == %Origin{by_actor_id: 100, initiator_user_id: 10, chain: []}
  end

  test "mcp with an hm_ token, as an external agent: the token's user, no chain" do
    for via <- [:mcp, :api] do
      scope = %Scope{user: @user, actor: @external, via: via}

      assert Origin.from_scope(scope) ==
               %Origin{by_actor_id: 200, initiator_user_id: 10, chain: []}
    end
  end

  test "run: the run's initiator and causal chain, not the agent's owner" do
    run = %Run{id: 1, root_initiator_user_id: 77, causal_agent_ids: [400, 300]}
    scope = %Scope{user: @user, actor: @managed, via: :run, run: run}

    assert Origin.from_scope(scope) ==
             %Origin{by_actor_id: 300, initiator_user_id: 77, chain: [400, 300]}
  end
end
