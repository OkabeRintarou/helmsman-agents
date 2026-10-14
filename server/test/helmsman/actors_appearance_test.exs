defmodule Helmsman.ActorsAppearanceTest do
  # update-actor-icons 3.4: the fields `Actors.appearance/1` adds (D3, D4
  # domain side): `avatar_icon`, `vendor` and `vendor_source`.
  use Helmsman.DataCase, async: true

  import Helmsman.ApiTokensFixtures, only: [agent_fixture: 3]
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures, only: [profile: 1]
  import Helmsman.SquadsFixtures

  alias Helmsman.{Actors, Agents, Avatars}
  alias Helmsman.Daemons.Runtime

  setup do
    ctx = squads_fixture()
    Map.put(ctx, :runtime_id, profile(ctx.agent).runtime_id)
  end

  defp vendor_of(scope, name),
    do: Map.take(Actors.appearance(scope)[name], [:vendor, :vendor_source])

  defp set_runtime_vendor(ctx, vendor),
    do: Repo.update_all(from(r in Runtime, where: r.id == ^ctx.runtime_id), set: [vendor: vendor])

  defp bind(ctx, attrs) do
    account = provider_account_fixture(ctx.alice, attrs)
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: account.id})
    account
  end

  test "an account with an icon: the icon, from the account, over the runtime's", ctx do
    set_runtime_vendor(ctx, "openai")
    bind(ctx, %{icon: "kimi"})
    assert vendor_of(ctx.alice_scope, "keel/dev") == %{vendor: "kimi", vendor_source: :account}
  end

  test "an account without an icon: inferred from its host", ctx do
    bind(ctx, %{base_url: "https://api.z.ai/api/anthropic"})
    assert vendor_of(ctx.alice_scope, "keel/dev") == %{vendor: "zai", vendor_source: :account}
  end

  test "an account nothing is inferred from: no vendor, still from the account", ctx do
    set_runtime_vendor(ctx, "zai")
    bind(ctx, %{base_url: "https://llm.internal.invalid/v1"})
    assert vendor_of(ctx.alice_scope, "keel/dev") == %{vendor: nil, vendor_source: :account}
  end

  test "no account: the runtime's vendor, also when it is offline or disabled", ctx do
    set_runtime_vendor(ctx, "zai")
    assert vendor_of(ctx.alice_scope, "keel/dev") == %{vendor: "zai", vendor_source: :runtime}

    Repo.update_all(from(r in Runtime, where: r.id == ^ctx.runtime_id),
      set: [status: "offline", disabled_at: DateTime.truncate(DateTime.utc_now(), :second)]
    )

    assert vendor_of(ctx.alice_scope, "keel/dev") == %{vendor: "zai", vendor_source: :runtime}
  end

  test "no account and a runtime without a vendor: none", ctx do
    assert vendor_of(ctx.alice_scope, "keel/dev") == %{vendor: nil, vendor_source: nil}
  end

  test "external agents, squads, humans and the system identity: none", ctx do
    set_runtime_vendor(ctx, "zai")
    external = agent_fixture(ctx.workspace, ctx.alice, "keel/ext")

    for name <- [external.name, "web-team", ctx.alice_scope.actor.name, "helmsman"] do
      assert vendor_of(ctx.alice_scope, name) == %{vendor: nil, vendor_source: nil}
    end
  end

  test "avatar_icon: own for agents and squads, the user's for humans", ctx do
    {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "zai")
    {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "web-team"}, "kimi")
    {:ok, _} = Avatars.put_icon(ctx.bob_scope, :me, "openai")

    appearance = Actors.appearance(ctx.alice_scope)
    assert %{avatar_icon: "zai", avatar_key: nil} = appearance["keel/dev"]
    assert %{avatar_icon: "kimi"} = appearance["web-team"]
    assert %{avatar_icon: "openai", avatar_key: nil} = appearance[ctx.bob_scope.actor.name]
    assert %{avatar_icon: nil} = appearance[ctx.alice_scope.actor.name]
    assert %{avatar_icon: nil} = appearance["helmsman"]
    # A user's icon is not their agents'.
    assert %{avatar_icon: nil} = appearance["keel/lead"]
  end

  test "one query, with every new field present", ctx do
    set_runtime_vendor(ctx, "zai")
    bind(ctx, %{icon: "kimi"})
    {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "zai")

    {appearance, queries} =
      Helmsman.QueryCount.count(fn -> Actors.appearance(ctx.alice_scope) end)

    assert queries == 1

    for {_name, item} <- appearance do
      assert Map.keys(item) |> Enum.sort() ==
               ~w(avatar_icon avatar_key kind managed? provider vendor vendor_source)a
    end

    assert %{avatar_icon: "zai", vendor: "kimi", vendor_source: :account} =
             appearance["keel/dev"]

    assert %{vendor: "zai", vendor_source: :runtime} = appearance["keel/lead"]
  end
end
