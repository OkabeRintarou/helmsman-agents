defmodule Helmsman.ProviderAccounts.ConcurrencyTest do
  # add-provider-accounts 3.2: concurrent creation and deletion against
  # binding (decisions 3, 14), each side on a connection of its own.
  use ExUnit.Case, async: false

  import Ecto.Query

  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.{Agents, CommittedData, LockHarness, ProviderAccounts, Repo}
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.ProviderAccounts.ProviderAccount

  @moduletag timeout: 60_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture()
        Map.put(ctx, :scope, Scope.for_user(ctx.alice))
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  defp count(user_id) do
    CommittedData.unboxed(fn ->
      Repo.aggregate(
        from(a in ProviderAccount, where: a.user_id == ^user_id),
        :count
      )
    end)
  end

  test "concurrent creations do not exceed the limit (scenario)", ctx do
    CommittedData.unboxed(fn ->
      for _ <- 1..31, do: provider_account_fixture(ctx.alice)
    end)

    create = fn -> ProviderAccounts.create(ctx.scope, valid_provider_account_attrs()) end

    {first, second} = LockHarness.interleave(create, :commit, create)

    assert {:ok, %{api_key_set: true}} = first
    assert second == {:error, :limit_reached}
    assert count(ctx.alice.id) == 32
  end

  describe "deletion and binding" do
    setup ctx do
      account =
        CommittedData.unboxed(fn -> provider_account_fixture(ctx.alice, %{name: "zai"}) end)

      Map.put(ctx, :account, account)
    end

    defp bind(ctx),
      do: fn ->
        Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: ctx.account.id})
      end

    defp delete(ctx), do: fn -> ProviderAccounts.delete(ctx.scope, ctx.account.id) end

    defp bound_id(ctx) do
      CommittedData.unboxed(fn ->
        Repo.get_by!(AgentProfile, actor_id: ctx.agent.id).provider_account_id
      end)
    end

    test "binding first: the deletion waits and finds it in use (scenario)", ctx do
      {bound, deleted} = LockHarness.interleave(bind(ctx), :commit, delete(ctx))

      assert {:ok, %{provider_account: %{name: "zai"}}} = bound
      assert {:error, {:in_use, [%{name: "keel/dev"}]}} = deleted
      assert bound_id(ctx) == ctx.account.id
    end

    test "deletion first: the binding waits and fails (scenario)", ctx do
      {deleted, bound} = LockHarness.interleave(delete(ctx), :commit, bind(ctx))

      assert deleted == :ok
      assert {:error, %Ecto.Changeset{} = cs} = bound
      assert {"does not exist", _} = cs.errors[:provider_account_id]
      assert bound_id(ctx) == nil
    end
  end
end
