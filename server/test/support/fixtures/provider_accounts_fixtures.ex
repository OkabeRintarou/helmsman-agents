defmodule Helmsman.ProviderAccountsFixtures do
  @moduledoc "Provider accounts created through `Helmsman.ProviderAccounts`."

  # Test-only helpers used by both domain and web test cases.
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.ProviderAccounts

  def valid_provider_account_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "acct-#{System.unique_integer([:positive])}",
      cli: "claude",
      base_url: "https://api.z.ai/api/anthropic",
      api_key: "sk-zai-1",
      models: %{"default" => "glm-5.3"}
    })
  end

  @doc "Creates an account of `user` (or of the user of `scope`); returns its view."
  def provider_account_fixture(user_or_scope, attrs \\ %{})

  def provider_account_fixture(%User{} = user, attrs),
    do: provider_account_fixture(Scope.for_user(user), attrs)

  def provider_account_fixture(%Scope{user: user}, attrs) do
    {:ok, account} =
      ProviderAccounts.create(Scope.for_user(user), valid_provider_account_attrs(attrs))

    account
  end
end
