defmodule Helmsman.Dispatch.AvailabilityTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Dispatch
  alias Helmsman.QueryCount

  setup do
    ctx = dispatch_fixture()
    Map.put(ctx, :runtime, Repo.get!(Runtime, profile(ctx.agent).runtime_id))
  end

  test "a member may not trigger an owner-only agent", ctx do
    {_bob, bob_scope} = member_scope_fixture(ctx.workspace)

    assert {:ok, %{"keel/dev" => %{result: {:skipped, :unauthorized}, runtime: runtime}}} =
             Dispatch.availability(bob_scope)

    assert runtime == %{
             daemon_name: "test-machine",
             provider: "claude",
             status: "online",
             disabled: false
           }
  end

  test "an offline runtime is still dispatchable", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.runtime, status: "offline"))

    assert {:ok, %{"keel/dev" => %{result: :ok, runtime: %{status: "offline"}}}} =
             Dispatch.availability(ctx.alice_scope)
  end

  test "disabled, unbound and runtime-disabled agents are skipped in order", ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/unbound", runtime_id: nil})

    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/disabled",
      runtime_id: nil,
      access: "workspace"
    })

    {:ok, _} = Agents.disable(ctx.alice_scope, "keel/disabled")
    {:ok, availability} = Dispatch.availability(ctx.alice_scope)

    assert %{result: {:skipped, :no_runtime}, runtime: nil} = availability["keel/unbound"]
    assert %{result: {:skipped, :agent_disabled}, runtime: nil} = availability["keel/disabled"]
    assert %{result: :ok} = availability["keel/dev"]

    Repo.update!(Ecto.Changeset.change(ctx.runtime, disabled_at: DateTime.utc_now(:second)))
    {:ok, availability} = Dispatch.availability(ctx.alice_scope)

    assert %{result: {:skipped, :runtime_disabled}, runtime: %{disabled: true}} =
             availability["keel/dev"]

    # Unauthorized comes before a disabled runtime.
    {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {:ok, availability} = Dispatch.availability(bob_scope)
    assert %{result: {:skipped, :unauthorized}} = availability["keel/dev"]
  end

  test "archived and external agents are absent", ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/old", runtime_id: nil})
    {:ok, _} = Agents.archive(ctx.alice_scope, "keel/old")

    Repo.insert!(
      Actor.create_changeset(
        %Actor{workspace_id: ctx.workspace.id, owner_id: ctx.alice.id, kind: :agent},
        %{name: "outside/bot"}
      )
    )

    assert {:ok, availability} = Dispatch.availability(ctx.alice_scope)
    assert Map.keys(availability) == ["keel/dev"]
  end

  test "agrees with trigger_check/3 for every role and access", ctx do
    users =
      for role <- [:member, :member, :admin, :viewer] do
        user = user_fixture()
        member_fixture(ctx.workspace, user, role)
        user
      end

    [listed | _] = users
    runtime_id = ctx.runtime.id

    agents =
      for access <- ["owner_only", "members", "workspace"] do
        managed_agent_fixture(ctx.alice_scope, %{
          name: "keel/#{access}",
          access: access,
          access_member_ids: [listed.id],
          runtime_id: runtime_id
        })

        agent_actor(ctx.workspace, "keel/#{access}")
      end

    for user <- [ctx.alice | users] do
      {:ok, availability} = Dispatch.availability(workspace_scope_fixture(user, ctx.workspace))

      for agent <- agents do
        expected =
          case Agents.trigger_check(ctx.workspace.id, user.id, agent) do
            :ok -> :ok
            {:error, reason} -> {:skipped, reason}
          end

        assert availability[agent.name].result == expected, "#{agent.name} for #{user.id}"
      end
    end
  end

  test "the number of queries does not depend on the number of agents", ctx do
    {{:ok, one}, few} = QueryCount.count(fn -> Dispatch.availability(ctx.alice_scope) end)
    assert map_size(one) == 1

    for n <- 1..19 do
      managed_agent_fixture(ctx.alice_scope, %{name: "bulk/#{n}", runtime_id: ctx.runtime.id})
    end

    {{:ok, many}, more} = QueryCount.count(fn -> Dispatch.availability(ctx.alice_scope) end)
    assert map_size(many) == 20
    assert Enum.all?(many, fn {_name, %{result: result}} -> result == :ok end)
    assert few == more
    assert more <= 3
  end

  test "needs :read_tasks", ctx do
    assert {:error, :forbidden} = Dispatch.availability(%{ctx.alice_scope | role: nil})
  end
end
