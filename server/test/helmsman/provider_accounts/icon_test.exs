defmodule Helmsman.ProviderAccounts.IconTest do
  # add-actor-avatars 7.5: provider-accounts「供应商账号的图标」(decision 19).
  use Helmsman.DataCase, async: true

  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.{Agents, ProviderAccounts}
  alias Helmsman.ProviderAccounts.ProviderAccount

  setup do
    ctx = dispatch_fixture()
    scope = Scope.for_user(ctx.alice)
    account = provider_account_fixture(ctx.alice, %{name: "zai"})
    Map.merge(ctx, %{scope: scope, account: account})
  end

  test "a new account has no icon (inferred by the interface)", ctx do
    assert ctx.account.icon == nil
  end

  test "setting the icon shows on the account and in the agents' account summary", ctx do
    assert {:ok, %{icon: "zai"}} =
             ProviderAccounts.update(ctx.scope, ctx.account.id, %{icon: "zai"})

    assert {:ok, %{icon: "zai"}} = ProviderAccounts.get(ctx.scope, ctx.account.id)
    assert {:ok, [%{icon: "zai"}]} = ProviderAccounts.list(ctx.scope)
    assert {:ok, [%{icon: "zai"}]} = ProviderAccounts.options(ctx.scope, "claude")

    {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: ctx.account.id})

    assert {:ok, %{provider_account: %{icon: "zai", name: "zai"}}} =
             Agents.get(ctx.alice_scope, "keel/dev")
  end

  test "any key of the format is accepted, from no fixed list", ctx do
    assert {:ok, %{icon: "x9"}} =
             ProviderAccounts.update(ctx.scope, ctx.account.id, %{icon: "x9"})

    long = String.duplicate("a", 32)

    assert {:ok, %{icon: ^long}} =
             ProviderAccounts.update(ctx.scope, ctx.account.id, %{icon: long})
  end

  test "an invalid icon is an error on icon and changes nothing", ctx do
    {:ok, _} = ProviderAccounts.update(ctx.scope, ctx.account.id, %{icon: "zai"})

    for bad <- ["Z.AI!", "Zai", "z-ai", String.duplicate("a", 33), "zai "] do
      assert {:error, %Ecto.Changeset{} = cs} =
               ProviderAccounts.update(ctx.scope, ctx.account.id, %{icon: bad})

      assert Keyword.has_key?(cs.errors, :icon), bad
    end

    assert Repo.get!(ProviderAccount, ctx.account.id).icon == "zai"

    assert {:error, %Ecto.Changeset{errors: [icon: _]}} =
             ProviderAccounts.create(ctx.scope, valid_provider_account_attrs(%{icon: "Z.AI!"}))
  end

  test "clearing the icon makes it null", ctx do
    {:ok, _} = ProviderAccounts.update(ctx.scope, ctx.account.id, %{icon: "zai"})
    assert {:ok, %{icon: nil}} = ProviderAccounts.update(ctx.scope, ctx.account.id, %{icon: ""})
    {:ok, _} = ProviderAccounts.update(ctx.scope, ctx.account.id, %{icon: "zai"})

    assert {:ok, %{icon: nil}} =
             ProviderAccounts.update(ctx.scope, ctx.account.id, %{"icon" => nil})

    assert Repo.get!(ProviderAccount, ctx.account.id).icon == nil
  end

  test "the form changeset carries the icon", ctx do
    {:ok, view} = ProviderAccounts.update(ctx.scope, ctx.account.id, %{icon: "zai"})
    {:ok, cs} = ProviderAccounts.change(ctx.scope, view)
    assert Ecto.Changeset.get_field(cs, :icon) == "zai"
  end

  test "the database refuses an invalid icon", ctx do
    assert_raise Postgrex.Error, ~r/provider_accounts_icon_format/, fn ->
      Repo.query!("UPDATE provider_accounts SET icon = 'Bad!' WHERE id = $1", [ctx.account.id])
    end
  end
end
