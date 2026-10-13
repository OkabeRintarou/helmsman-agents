defmodule Helmsman.ProviderAccountsTest do
  # add-provider-accounts 3.2: ownership, write-only keys, deletion and
  # notifications (provider-accounts, decision 3). The concurrent cases are
  # in provider_accounts/concurrency_test.exs (connections of their own).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.{Agents, Events, ProviderAccounts}
  alias Helmsman.ProviderAccounts.ProviderAccount

  setup do
    ctx = dispatch_fixture()
    Map.put(ctx, :scope, Scope.for_user(ctx.alice))
  end

  defp zai(ctx, attrs \\ %{}),
    do: provider_account_fixture(ctx.alice, Map.merge(%{name: "zai"}, attrs))

  defp stored(id), do: Repo.get(ProviderAccount, id)

  # The seven public functions, with arguments that would succeed for alice.
  defp calls(account) do
    [
      list: &ProviderAccounts.list(&1),
      get: &ProviderAccounts.get(&1, account.id),
      create: &ProviderAccounts.create(&1, valid_provider_account_attrs()),
      update: &ProviderAccounts.update(&1, account.id, %{name: "renamed", api_key: "sk-x"}),
      change: &ProviderAccounts.change(&1, account, %{name: "renamed"}),
      delete: &ProviderAccounts.delete(&1, account.id),
      options: &ProviderAccounts.options(&1, "claude")
    ]
  end

  describe "ownership" do
    test "create and list (scenario)", ctx do
      assert {:ok, %{id: id}} =
               ProviderAccounts.create(ctx.scope, %{
                 name: "zai",
                 cli: "claude",
                 base_url: "https://api.z.ai/api/anthropic",
                 api_key: "sk-zai-1",
                 models: %{default: "glm-5.3"}
               })

      assert {:ok, [account]} = ProviderAccounts.list(ctx.scope)

      assert %{
               id: ^id,
               name: "zai",
               cli: "claude",
               base_url: "https://api.z.ai/api/anthropic",
               models: %{"default" => "glm-5.3"},
               api_key_set: true,
               agents: []
             } = account
    end

    test "another user's account (scenario)", ctx do
      account = zai(ctx)
      bob = Scope.for_user(user_fixture())

      assert ProviderAccounts.get(bob, account.id) == {:error, :not_found}
      assert ProviderAccounts.update(bob, account.id, %{name: "mine"}) == {:error, :not_found}
      assert ProviderAccounts.delete(bob, account.id) == {:error, :not_found}
      assert ProviderAccounts.get(bob, -1) == {:error, :not_found}
      assert ProviderAccounts.get(bob, "x") == {:error, :not_found}
      assert ProviderAccounts.list(bob) == {:ok, []}
      assert ProviderAccounts.options(bob, "claude") == {:ok, []}
      assert %{name: "zai"} = stored(account.id)
    end

    test "instance administrators have no access either", ctx do
      account = zai(ctx)
      admin = Scope.for_user(%{user_fixture() | instance_admin: true})
      assert ProviderAccounts.get(admin, account.id) == {:error, :not_found}
    end

    test "a run token, even of the account's owner (scenario)", ctx do
      account = zai(ctx)
      before = stored(account.id)
      run = run_fixture(ctx.agent, %{status: :running, capabilities: ["read", "create_tasks"]})
      {run_scope, _token} = run_scope_fixture(run)
      assert run_scope.user.id == ctx.alice.id

      Events.subscribe(ProviderAccounts.topic(ctx.alice.id))
      Events.subscribe(Events.topic(:workspace, ctx.workspace.id))

      for {name, call} <- calls(account) do
        assert call.(run_scope) == {:error, :forbidden}, "#{name}"
      end

      assert stored(account.id) == before
      assert Repo.aggregate(ProviderAccount, :count) == 1
      refute_receive {:provider_accounts_changed}, 100
      refute_receive {:agents_changed}, 10
    end

    test "an API token, even a person's own (scenario)", ctx do
      account = zai(ctx)
      %{api_token: token} = api_token_fixture(ctx.alice_scope)

      for via <- [:mcp, :api] do
        scope = token_scope_fixture(ctx.alice, ctx.workspace, via, token)

        for {name, call} <- calls(account),
            do: assert(call.(scope) == {:error, :forbidden}, "#{via} #{name}")
      end
    end

    test "an agent identity", ctx do
      account = zai(ctx)
      scope = %{ctx.alice_scope | actor: ctx.agent}
      for {_name, call} <- calls(account), do: assert(call.(scope) == {:error, :forbidden})
    end

    test "the web session, also inside a workspace page", ctx do
      account = zai(ctx)

      for scope <- [ctx.scope, ctx.alice_scope] do
        assert {:ok, [_]} = ProviderAccounts.list(scope)
        assert {:ok, [%{id: id}]} = ProviderAccounts.options(scope, :claude)
        assert id == account.id
      end
    end

    test "a duplicate name, ignoring case (scenario)", ctx do
      zai(ctx)

      assert {:error, cs} =
               ProviderAccounts.create(ctx.scope, valid_provider_account_attrs(%{name: "ZAI"}))

      assert %{name: [_]} = errors_on(cs)
      assert Repo.aggregate(ProviderAccount, :count) == 1

      # Another user may use the name.
      assert {:ok, _} =
               ProviderAccounts.create(
                 Scope.for_user(user_fixture()),
                 valid_provider_account_attrs(%{name: "zai"})
               )
    end
  end

  describe "options" do
    test "only the user's accounts for that CLI, with their models", ctx do
      zai(ctx)
      provider_account_fixture(ctx.alice, %{name: "oai", cli: "codex", models: %{default: "o"}})
      provider_account_fixture(user_fixture(), %{name: "other", cli: "codex"})

      assert {:ok, [%{name: "oai", models: %{"default" => "o"}, base_url: _, id: _} = option]} =
               ProviderAccounts.options(ctx.scope, "codex")

      assert Map.keys(option) |> Enum.sort() == [:base_url, :headers, :id, :models, :name]
    end
  end

  describe "the key is write-only" do
    test "a read only says it is set (scenario)", ctx do
      account = zai(ctx)
      {:ok, view} = ProviderAccounts.get(ctx.scope, account.id)
      {:ok, list} = ProviderAccounts.list(ctx.scope)
      {:ok, cs} = ProviderAccounts.change(ctx.scope, view, %{})

      assert view.api_key_set
      refute Map.has_key?(view, :api_key)

      for value <- [view, list, cs, cs.data],
          do: refute(inspect(value, limit: :infinity) =~ "sk-zai-1")
    end

    test "an empty key keeps the stored one (scenario)", ctx do
      account = zai(ctx)

      for key <- ["", nil] do
        assert {:ok, %{name: "zai-2"}} =
                 ProviderAccounts.update(ctx.scope, account.id, %{name: "zai-2", api_key: key})

        assert stored(account.id).api_key == "sk-zai-1"
      end

      assert {:ok, _} = ProviderAccounts.update(ctx.scope, account.id, %{api_key: "sk-zai-2"})
      assert stored(account.id).api_key == "sk-zai-2"
    end

    test "a failure does not leak either key (scenario)", ctx do
      account = zai(ctx)
      before = stored(account.id)

      assert {:error, cs} =
               ProviderAccounts.update(ctx.scope, account.id, %{
                 api_key: "sk-new-2",
                 base_url: "http://api.example.com"
               })

      assert %{base_url: [_]} = errors_on(cs)
      text = inspect(cs, limit: :infinity) <> inspect(cs.params) <> inspect(cs.data)
      refute text =~ "sk-new-2"
      refute text =~ "sk-zai-1"
      assert stored(account.id) == before

      assert {:error, cs} =
               ProviderAccounts.create(
                 ctx.scope,
                 valid_provider_account_attrs(%{api_key: "sk-new-3", models: %{"gpt" => "x"}})
               )

      refute inspect({cs, cs.params, cs.data}, limit: :infinity) =~ "sk-new-3"

      assert {:ok, form} = ProviderAccounts.change(ctx.scope, nil, %{api_key: "sk-new-4"})
      refute inspect({form, form.params, form.changes}, limit: :infinity) =~ "sk-new-4"
    end
  end

  describe "models: null (code-review-2 P2)" do
    test "create, update and change return a models error", ctx do
      assert {:error, cs} =
               ProviderAccounts.create(
                 ctx.scope,
                 valid_provider_account_attrs(%{models: nil, api_key: "sk-null-1"})
               )

      assert %{models: ["must be an object"]} = errors_on(cs)
      refute inspect({cs, cs.params, cs.data}, limit: :infinity) =~ "sk-null-1"
      assert Repo.aggregate(ProviderAccount, :count) == 0

      account = zai(ctx)
      before = stored(account.id)

      assert {:error, cs} =
               ProviderAccounts.update(ctx.scope, account.id, %{
                 "models" => nil,
                 "api_key" => "sk-null-2"
               })

      assert %{models: ["must be an object"]} = errors_on(cs)
      text = inspect({cs, cs.params, cs.data}, limit: :infinity)
      refute text =~ "sk-null-2"
      refute text =~ "sk-zai-1"

      assert stored(account.id) == before

      {:ok, view} = ProviderAccounts.get(ctx.scope, account.id)
      assert {:ok, form} = ProviderAccounts.change(ctx.scope, view, %{models: nil})
      assert %{models: ["must be an object"]} = errors_on(form)
      assert {:ok, form} = ProviderAccounts.change(ctx.scope, nil, %{models: nil})
      assert %{models: ["must be an object"]} = errors_on(form)
    end

    test "leaving models out keeps them", ctx do
      account = zai(ctx)

      assert {:ok, %{models: %{"default" => "glm-5.3"}}} =
               ProviderAccounts.update(ctx.scope, account.id, %{name: "zai-2"})
    end
  end

  describe "change/3" do
    test "an existing account's form does not ask for the key", ctx do
      {:ok, view} = ProviderAccounts.get(ctx.scope, zai(ctx).id)
      assert {:ok, %Ecto.Changeset{valid?: true}} = ProviderAccounts.change(ctx.scope, view, %{})

      assert {:ok, %Ecto.Changeset{valid?: false} = cs} =
               ProviderAccounts.change(ctx.scope, nil, %{name: "x"})

      assert %{api_key: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "deletion" do
    setup ctx do
      account = zai(ctx)
      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: account.id})
      Map.put(ctx, :account, account)
    end

    test "in use (scenario)", ctx do
      assert ProviderAccounts.delete(ctx.scope, ctx.account.id) ==
               {:error, {:in_use, [%{workspace_slug: ctx.workspace.slug, name: "keel/dev"}]}}

      assert stored(ctx.account.id)
    end

    test "only archived agents refer to it (scenario)", ctx do
      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/dev")
      assert {:ok, %{agents: []}} = ProviderAccounts.get(ctx.scope, ctx.account.id)
      assert ProviderAccounts.delete(ctx.scope, ctx.account.id) == :ok
      refute stored(ctx.account.id)
      assert profile(ctx.agent).provider_account_id == nil
    end

    test "runs that used it keep no account", ctx do
      run = run_fixture(ctx.agent, %{provider_account_id: ctx.account.id})
      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: nil})
      assert ProviderAccounts.delete(ctx.scope, ctx.account.id) == :ok
      assert Repo.reload!(run).provider_account_id == nil
    end

    test "the view lists unarchived agents in every workspace, by slug and name", ctx do
      other = Helmsman.WorkspacesFixtures.workspace_fixture(ctx.alice, %{slug: "aaa"})
      other_scope = Helmsman.WorkspacesFixtures.workspace_scope_fixture(ctx.alice, other)
      managed_agent_fixture(other_scope, %{name: "aaa/x", provider_account_id: ctx.account.id})

      managed_agent_fixture(ctx.alice_scope, %{
        name: "keel/a",
        provider_account_id: ctx.account.id
      })

      managed_agent_fixture(ctx.alice_scope, %{
        name: "keel/old",
        provider_account_id: ctx.account.id
      })

      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/old")

      assert {:ok, %{agents: agents}} = ProviderAccounts.get(ctx.scope, ctx.account.id)

      assert agents == [
               %{workspace_slug: "aaa", name: "aaa/x"},
               %{workspace_slug: ctx.workspace.slug, name: "keel/a"},
               %{workspace_slug: ctx.workspace.slug, name: "keel/dev"}
             ]
    end
  end

  describe "notifications" do
    test "renaming a bound account (scenario)", ctx do
      account = zai(ctx)
      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: account.id})
      Events.subscribe(ProviderAccounts.topic(ctx.alice.id))
      Events.subscribe(Events.topic(:workspace, ctx.workspace.id))

      assert {:ok, _} = ProviderAccounts.update(ctx.scope, account.id, %{name: "zai-2"})
      assert_receive {:provider_accounts_changed}
      assert_receive {:agents_changed}
    end

    test "create and delete notify the user; failures notify nobody", ctx do
      Events.subscribe(ProviderAccounts.topic(ctx.alice.id))
      account = zai(ctx)
      assert_receive {:provider_accounts_changed}
      assert :ok = ProviderAccounts.delete(ctx.scope, account.id)
      assert_receive {:provider_accounts_changed}

      assert {:error, _} = ProviderAccounts.create(ctx.scope, %{name: "x"})
      assert {:error, :not_found} = ProviderAccounts.update(ctx.scope, account.id, %{name: "y"})
      assert {:error, :not_found} = ProviderAccounts.delete(ctx.scope, account.id)
      refute_receive {:provider_accounts_changed}, 100
    end

    test "the topic", ctx do
      assert ProviderAccounts.topic(ctx.alice.id) == "user:#{ctx.alice.id}:provider_accounts"

      assert Events.topic(:provider_accounts, ctx.alice.id) ==
               ProviderAccounts.topic(ctx.alice.id)
    end
  end
end
