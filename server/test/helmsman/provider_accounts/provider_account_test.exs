defmodule Helmsman.ProviderAccounts.ProviderAccountTest do
  # add-provider-accounts 3.1: the fields of a provider account
  # (provider-accounts「供应商账号的字段校验」, decision 2).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProviderAccountsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.ProviderAccounts
  alias Helmsman.ProviderAccounts.ProviderAccount

  setup do
    alice = user_fixture()
    %{alice: alice, scope: Scope.for_user(alice)}
  end

  defp create(ctx, attrs),
    do: ProviderAccounts.create(ctx.scope, valid_provider_account_attrs(attrs))

  defp error_on(ctx, attrs, field) do
    assert {:error, %Ecto.Changeset{} = cs} = create(ctx, attrs)
    assert Map.has_key?(errors_on(cs), field), inspect(errors_on(cs))
    errors_on(cs)[field]
  end

  describe "scenarios" do
    test "plain http address", ctx do
      error_on(ctx, %{base_url: "http://api.example.com/anthropic"}, :base_url)
      assert {:ok, _} = create(ctx, %{base_url: "http://127.0.0.1:8080"})
    end

    test "an address with credentials", ctx do
      error_on(ctx, %{base_url: "https://user:pass@api.example.com"}, :base_url)
      error_on(ctx, %{base_url: "https://api.example.com/v1?key=abc"}, :base_url)
      error_on(ctx, %{base_url: "https://api.example.com/v1#frag"}, :base_url)
    end

    test "a codex account without a default model", ctx do
      error_on(ctx, %{cli: "codex", models: %{}}, :models)
      assert {:ok, _} = create(ctx, %{cli: "codex", models: %{"default" => "glm-5.3"}})
    end

    test "an unknown alias", ctx do
      assert [message] = error_on(ctx, %{models: %{"gpt" => "x"}}, :models)
      assert message =~ "gpt"
      error_on(ctx, %{cli: "codex", models: %{"default" => "x", "opus" => "y"}}, :models)
    end

    test "changing the CLI", ctx do
      account = provider_account_fixture(ctx.alice)

      assert {:error, cs} = ProviderAccounts.update(ctx.scope, account.id, %{cli: "codex"})
      assert %{cli: ["cannot be changed"]} = errors_on(cs)
      assert {:ok, %{cli: "claude"}} = ProviderAccounts.get(ctx.scope, account.id)
    end
  end

  describe "boundaries" do
    test "name: trimmed, 1-64 characters, no control characters", ctx do
      assert {:ok, %{name: name}} = create(ctx, %{name: "  " <> String.duplicate("é", 64) <> " "})
      assert name == String.duplicate("é", 64)
      error_on(ctx, %{name: String.duplicate("a", 65)}, :name)
      error_on(ctx, %{name: "   "}, :name)
      error_on(ctx, %{name: "a\tb"}, :name)
    end

    test "the 33rd account is refused", ctx do
      for _ <- 1..32, do: provider_account_fixture(ctx.alice)
      assert create(ctx, %{}) == {:error, :limit_reached}
      assert {:ok, accounts} = ProviderAccounts.list(ctx.scope)
      assert length(accounts) == 32
    end

    test "the trailing / is removed", ctx do
      assert {:ok, %{base_url: "https://api.z.ai/api/anthropic"}} =
               create(ctx, %{base_url: "https://api.z.ai/api/anthropic/"})

      assert {:ok, %{base_url: "https://api.z.ai"}} =
               create(ctx, %{base_url: "https://api.z.ai/"})
    end

    test "loopback hosts may use http", ctx do
      for url <- ~w(http://[::1]:9000 http://127.0.0.2 http://localhost:8080/v1) do
        assert {:ok, %{base_url: ^url}} = create(ctx, %{base_url: url})
      end

      for url <- ~w(http://10.0.0.1 http://localhost.example.com ftp://127.0.0.1 api.z.ai) do
        error_on(ctx, %{base_url: url}, :base_url)
      end
    end

    test "address: at most 2048 bytes", ctx do
      prefix = "https://api.z.ai/"
      ok = prefix <> String.duplicate("a", 2048 - byte_size(prefix))
      assert {:ok, _} = create(ctx, %{base_url: ok})
      error_on(ctx, %{base_url: ok <> "a"}, :base_url)
    end

    test "key: required, 1-8192 visible ASCII characters", ctx do
      error_on(ctx, %{api_key: ""}, :api_key)
      error_on(ctx, %{api_key: "sk zai"}, :api_key)
      error_on(ctx, %{api_key: "sk-é"}, :api_key)
      error_on(ctx, %{api_key: String.duplicate("k", 8193)}, :api_key)
      assert {:ok, _} = create(ctx, %{api_key: String.duplicate("k", 8192)})
    end

    test "model names: 1-128 visible ASCII characters", ctx do
      assert {:ok, %{models: models}} =
               create(ctx, %{
                 models: %{
                   default: String.duplicate("m", 128),
                   opus: "o",
                   sonnet: "s",
                   haiku: "h",
                   fable: "f",
                   subagent: "x"
                 }
               })

      assert map_size(models) == 6
      error_on(ctx, %{models: %{"default" => String.duplicate("m", 129)}}, :models)
      error_on(ctx, %{models: %{"default" => ""}}, :models)
      error_on(ctx, %{models: %{"default" => "glm 5"}}, :models)
      error_on(ctx, %{models: %{"default" => 5}}, :models)
    end
  end

  test "the key is not stored in plain text and never shown", ctx do
    account = provider_account_fixture(ctx.alice, %{api_key: "sk-zai-plain-1"})

    %{rows: [[stored]]} =
      Repo.query!("SELECT api_key FROM provider_accounts WHERE id = $1", [account.id])

    refute stored =~ "sk-zai-plain-1"
    assert Repo.get!(ProviderAccount, account.id).api_key == "sk-zai-plain-1"
    refute inspect(Repo.get!(ProviderAccount, account.id)) =~ "sk-zai-plain-1"
    refute inspect(account) =~ "sk-zai-plain-1"
  end
end
