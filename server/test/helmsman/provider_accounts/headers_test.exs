defmodule Helmsman.ProviderAccounts.HeadersTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AccountsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures
  alias Ecto.Adapters.SQL
  alias Helmsman.Accounts.Scope
  alias Helmsman.{Agents, Events, ProviderAccounts}
  alias Helmsman.ProviderAccounts.ProviderAccount

  setup do
    ctx = dispatch_fixture()
    Map.put(ctx, :scope, Scope.for_user(ctx.alice))
  end

  defp attrs(extra \\ %{}) do
    valid_provider_account_attrs(
      Map.merge(
        %{
          cli: "codex",
          models: %{"default" => "model"},
          headers: %{
            "Ocp-Apim-Subscription-Key" => "header-one-sentinel",
            "user" => "header-two-sentinel"
          }
        },
        extra
      )
    )
  end

  defp safe(value) do
    text = inspect(value, limit: :infinity)

    for secret <- ["header-one-sentinel", "header-two-sentinel", "new-header-sentinel"],
        do: refute(text =~ secret)
  end

  test "create encrypts headers and every public read returns only names", ctx do
    Events.subscribe(ProviderAccounts.topic(ctx.alice.id))
    assert {:ok, account} = ProviderAccounts.create(ctx.scope, attrs())
    assert account.headers == ["Ocp-Apim-Subscription-Key", "user"]
    assert_receive notification = {:provider_accounts_changed}
    assert {:ok, view} = ProviderAccounts.get(ctx.scope, account.id)
    assert {:ok, list} = ProviderAccounts.list(ctx.scope)
    assert {:ok, options} = ProviderAccounts.options(ctx.scope, :codex)
    assert {:ok, cs} = ProviderAccounts.change(ctx.scope, view)
    assert {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: nil})

    for value <- [account, view, list, options, cs, cs.data, cs.params, notification],
        do: safe(value)

    stored = Repo.get!(ProviderAccount, account.id)
    safe(stored)

    assert JSON.decode!(stored.headers) == [
             %{"name" => "Ocp-Apim-Subscription-Key", "value" => "header-one-sentinel"},
             %{"name" => "user", "value" => "header-two-sentinel"}
           ]

    assert %{rows: [[encrypted]]} =
             SQL.query!(Repo, "SELECT headers FROM provider_accounts WHERE id=$1", [
               account.id
             ])

    refute encrypted =~ "header-one-sentinel"
    refute encrypted =~ "header-two-sentinel"
    assert {:error, :not_found} = ProviderAccounts.get(Scope.for_user(user_fixture()), account.id)
  end

  test "Phoenix parameter filtering hides API keys and header values" do
    params = %{
      "account" => %{
        "headers" => %{"user" => "header-one-sentinel"},
        "api_key" => "new-header-sentinel"
      }
    }

    safe(Phoenix.Logger.filter_values(params))
  end

  test "patch replaces ignoring case, deletes and preserves untouched headers", ctx do
    assert {:ok, account} = ProviderAccounts.create(ctx.scope, attrs())

    assert {:ok, updated} =
             ProviderAccounts.update(ctx.scope, account.id, %{
               headers: %{
                 "set" => %{"USER" => "new-header-sentinel", "X-Extra" => "extra"},
                 "delete" => ["ocp-apim-subscription-key"]
               }
             })

    assert updated.headers == ["USER", "X-Extra"]
    assert {:ok, _} = ProviderAccounts.update(ctx.scope, account.id, %{name: "renamed"})

    assert JSON.decode!(Repo.get!(ProviderAccount, account.id).headers) == [
             %{"name" => "USER", "value" => "new-header-sentinel"},
             %{"name" => "X-Extra", "value" => "extra"}
           ]

    safe(updated)

    assert {:ok, cleared} =
             ProviderAccounts.update(ctx.scope, account.id, %{
               headers: %{"delete" => ["user", "X-Extra"]}
             })

    assert cleared.headers == []
    assert Repo.get!(ProviderAccount, account.id).headers == nil
  end

  test "reserved names and Claude accounts fail without saving or exposing headers", ctx do
    for reserved <-
          ~w(authorization Proxy-Authorization Host Content-Length Content-Type Transfer-Encoding Connection Upgrade TE Trailer Keep-Alive) do
      assert {:error, cs} =
               ProviderAccounts.create(
                 ctx.scope,
                 attrs(%{headers: %{reserved => "new-header-sentinel"}})
               )

      assert %{headers: [message]} = errors_on(cs)
      assert message =~ reserved
      safe({cs, cs.params, cs.data, errors_on(cs)})
    end

    assert {:error, cs} = ProviderAccounts.create(ctx.scope, attrs(%{cli: "claude"}))
    assert %{headers: ["Claude Code accounts do not support custom headers yet"]} = errors_on(cs)
    safe({cs, cs.params, cs.data})
    assert Repo.aggregate(ProviderAccount, :count) == 0
  end

  test "invalid patches, duplicates and ninth header preserve stored state and send no notification",
       ctx do
    assert {:ok, account} = ProviderAccounts.create(ctx.scope, attrs())
    before = Repo.get!(ProviderAccount, account.id)
    Events.subscribe(ProviderAccounts.topic(ctx.alice.id))

    patches = [
      %{"set" => %{"USER" => "new-header-sentinel"}, "delete" => ["user"]},
      %{"delete" => ["unknown"]},
      %{"delete" => ["user", "USER"]},
      %{"set" => %{"X" => "new-header-sentinel", "x" => "header-one-sentinel"}},
      %{"set" => Map.new(1..7, &{"X-#{&1}", "new-header-sentinel"})},
      %{"set" => %{"x" => "new-header-sentinel\r"}},
      %{"set" => nil},
      %{"delete" => nil},
      nil
    ]

    for patch <- patches do
      assert {:error, cs} = ProviderAccounts.update(ctx.scope, account.id, %{headers: patch})
      assert %{headers: [_]} = errors_on(cs)
      safe({cs, cs.params, cs.changes, cs.data, errors_on(cs)})
      assert Repo.get!(ProviderAccount, account.id) == before
    end

    refute_receive {:provider_accounts_changed}
  end

  test "name/value/count boundaries and form errors scrub all values", ctx do
    eight = Map.new(1..8, &{"X-#{&1}", "value"})
    assert {:ok, _} = ProviderAccounts.create(ctx.scope, attrs(%{headers: eight}))

    assert {:ok, _} =
             ProviderAccounts.create(
               ctx.scope,
               attrs(%{headers: %{String.duplicate("X", 64) => String.duplicate("v", 4096)}})
             )

    invalid = [
      Map.put(eight, "X-9", "new-header-sentinel"),
      %{"user" => "header-one-sentinel", "USER" => "header-two-sentinel"},
      %{String.duplicate("X", 65) => "new-header-sentinel"},
      %{"x" => String.duplicate("v", 4097)},
      %{"x" => " new-header-sentinel"},
      %{"x" => "new-header-sentinel "},
      %{"x" => "new-header-sentinel\n"},
      %{"x" => ""}
    ]

    for headers <- invalid do
      raw = ProviderAccount.changeset(%ProviderAccount{}, attrs(%{headers: headers}))
      safe({raw, raw.params, raw.changes, raw.data})
      assert {:error, cs} = ProviderAccounts.create(ctx.scope, attrs(%{headers: headers}))
      assert %{headers: [_]} = errors_on(cs)
      safe({cs, cs.params, cs.data})
      assert {:ok, cs} = ProviderAccounts.change(ctx.scope, nil, attrs(%{headers: headers}))
      safe({cs, cs.params, cs.changes, cs.data})
    end
  end
end
