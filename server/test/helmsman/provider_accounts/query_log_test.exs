defmodule Helmsman.ProviderAccounts.QueryLogTest do
  use Helmsman.DataCase, async: false

  import ExUnit.CaptureLog
  import Helmsman.AccountsFixtures
  import Helmsman.ProviderAccountsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.ProviderAccounts

  @secrets ~w(QUERY_KEY_SENTINEL QUERY_HEADER_SENTINEL ROTATED_KEY_SENTINEL ROTATED_HEADER_SENTINEL)

  setup do
    scope = Scope.for_user(user_fixture())
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    %{scope: scope}
  end

  defp attrs do
    valid_provider_account_attrs(%{
      cli: "codex",
      api_key: "QUERY_KEY_SENTINEL",
      headers: %{"user" => "QUERY_HEADER_SENTINEL"}
    })
  end

  defp capture_queries(fun) do
    log = capture_log([level: :debug], fun)
    # Prove Repo debug logging is active: disabling every query would hide the bug.
    assert log =~ "QUERY OK"
    assert log =~ "SELECT"
    assert Enum.all?(@secrets, &(not String.contains?(log, &1)))
    log
  end

  test "creating Codex and Claude accounts hides key and header write parameters", %{scope: scope} do
    for attributes <- [attrs(), %{attrs() | cli: "claude", headers: %{}}] do
      log =
        capture_queries(fn -> assert {:ok, _} = ProviderAccounts.create(scope, attributes) end)

      refute log =~ "INSERT INTO \"provider_accounts\""
    end
  end

  test "rotating key and headers hides update parameters while account reads remain logged", %{
    scope: scope
  } do
    {:ok, account} = ProviderAccounts.create(scope, attrs())

    log =
      capture_queries(fn ->
        assert {:ok, updated} =
                 ProviderAccounts.update(scope, account.id, %{
                   api_key: "ROTATED_KEY_SENTINEL",
                   headers: %{"set" => %{"user" => "ROTATED_HEADER_SENTINEL"}}
                 })

        assert updated.headers == ["user"]
        assert {:ok, _} = ProviderAccounts.get(scope, account.id)
        assert {:ok, _} = ProviderAccounts.list(scope)
      end)

    refute log =~ "UPDATE \"provider_accounts\""
  end

  test "failed inserts and updates do not log sensitive parameters", %{scope: scope} do
    attributes = attrs()
    {:ok, account} = ProviderAccounts.create(scope, attributes)
    {:ok, _} = ProviderAccounts.create(scope, %{attributes | name: "taken-name"})

    capture_queries(fn ->
      assert {:error, insert} = ProviderAccounts.create(scope, attributes)
      assert %{name: [_]} = errors_on(insert)

      assert {:error, update} =
               ProviderAccounts.update(scope, account.id, %{
                 name: "taken-name",
                 api_key: "ROTATED_KEY_SENTINEL",
                 headers: %{"set" => %{"user" => "ROTATED_HEADER_SENTINEL"}}
               })

      assert %{name: [_]} = errors_on(update)
    end)
  end
end
