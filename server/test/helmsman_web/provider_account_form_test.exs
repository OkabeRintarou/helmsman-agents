defmodule HelmsmanWeb.ProviderAccountFormTest do
  @moduledoc "add-provider-accounts-ui D5: the attrs of the account panel and its CLI switch."
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProviderAccountsFixtures

  alias Helmsman.Accounts.Scope
  alias HelmsmanWeb.ProviderAccountForm

  setup do
    user = user_fixture()
    %{scope: Scope.for_user(user), user: user}
  end

  defp with_params(form, params), do: %{form | params: Map.merge(form.params, params)}

  describe "attrs/2" do
    test "a new account: every field, the CLI, non-empty models of the CLI only" do
      form =
        ProviderAccountForm.new(1)
        |> with_params(%{
          "name" => "zai",
          "cli" => "claude",
          "base_url" => "https://api.z.ai/api/anthropic",
          "models" => %{"default" => " glm-5.3 ", "opus" => "", "haiku" => "glm-4.7-air"}
        })

      assert ProviderAccountForm.attrs(form, %{"api_key" => "sk-new-1"}) == %{
               "name" => "zai",
               "cli" => "claude",
               "base_url" => "https://api.z.ai/api/anthropic",
               "models" => %{"default" => "glm-5.3", "haiku" => "glm-4.7-air"},
               "api_key" => "sk-new-1"
             }
    end

    test "an edit never carries the CLI; an empty key is not submitted", ctx do
      zai = provider_account_fixture(ctx.user, %{name: "zai"})
      form = ProviderAccountForm.edit(1, zai)

      attrs = ProviderAccountForm.attrs(form, %{"api_key" => ""})
      refute Map.has_key?(attrs, "cli")
      refute Map.has_key?(attrs, "api_key")
      assert attrs["name"] == "zai"

      refute Map.has_key?(ProviderAccountForm.attrs(form, %{}), "api_key")
    end

    test "aliases of another CLI are dropped" do
      form =
        ProviderAccountForm.new(1)
        |> with_params(%{"cli" => "codex", "models" => %{"default" => "gpt-5", "opus" => "x"}})

      assert ProviderAccountForm.attrs(form, %{})["models"] == %{"default" => "gpt-5"}
    end
  end

  describe "change/3" do
    test "switching the CLI of a new account keeps only default", ctx do
      form =
        ProviderAccountForm.new(1)
        |> ProviderAccountForm.change(ctx.scope, %{
          "account" => %{"cli" => "claude", "models" => %{"default" => "glm", "opus" => "o"}}
        })

      assert form.params["models"] == %{"default" => "glm", "opus" => "o"}

      form =
        ProviderAccountForm.change(form, ctx.scope, %{
          "account" => %{"cli" => "codex", "models" => %{"default" => "glm", "opus" => "o"}}
        })

      assert form.params["cli"] == "codex"
      assert form.params["models"] == %{"default" => "glm"}
    end

    test "the key never reaches the state and its errors are not shown", ctx do
      form =
        ProviderAccountForm.change(ProviderAccountForm.new(1), ctx.scope, %{
          "account" => %{"name" => "zai", "api_key" => "sk-sentinel-1", "base_url" => ""}
        })

      refute inspect(form) =~ "sk-sentinel-1"
      refute Map.has_key?(form.errors, :api_key)
    end

    test "only the inputs already used show errors", ctx do
      form =
        ProviderAccountForm.change(ProviderAccountForm.new(1), ctx.scope, %{
          "account" => %{
            "name" => "zai",
            "base_url" => "http://api.example.com",
            "_unused_name" => ""
          }
        })

      assert form.errors[:base_url]
      refute form.errors[:name]
    end

    test "an edit cannot change the CLI", ctx do
      zai = provider_account_fixture(ctx.user, %{name: "zai"})

      form =
        ProviderAccountForm.change(ProviderAccountForm.edit(1, zai), ctx.scope, %{
          "account" => %{"cli" => "codex"}
        })

      assert form.params["cli"] == "claude"
    end
  end
end
