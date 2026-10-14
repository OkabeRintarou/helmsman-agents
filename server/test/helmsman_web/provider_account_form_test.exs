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
               "icon" => nil,
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

  # add-provider-account-headers 决策 11: what the headers group submits.
  describe "header_attrs/2" do
    defp codex_view(headers) do
      %{
        id: 1,
        name: "apim",
        cli: "codex",
        base_url: "https://gw.example.com/openai/v1",
        models: %{"default" => "gpt-6-luna"},
        headers: headers,
        agents: []
      }
    end

    defp with_rows(form, n),
      do: Enum.reduce(1..n//1, form, fn _, f -> ProviderAccountForm.add_row(f) end)

    defp name_rows(form, names) do
      rows = Enum.zip_with(form.rows, names, fn row, name -> %{row | name: name} end)
      %{form | rows: rows}
    end

    defp new_codex, do: ProviderAccountForm.new(1) |> with_params(%{"cli" => "codex"})

    test "a new account: all its rows, blank rows skipped" do
      form = new_codex() |> with_rows(3) |> name_rows([" user ", "", "x-only-name"])

      raw = %{"headers_password" => %{"new" => %{"1" => "u-1", "2" => ""}}}

      assert ProviderAccountForm.header_attrs(form, raw) == %{
               "user" => "u-1",
               "x-only-name" => ""
             }

      assert ProviderAccountForm.attrs(form, raw)["headers"] == %{
               "user" => "u-1",
               "x-only-name" => ""
             }
    end

    test "no rows, or a Claude Code account: no headers at all" do
      assert ProviderAccountForm.header_attrs(new_codex(), %{}) == nil

      claude =
        ProviderAccountForm.new(1)
        |> with_params(%{"cli" => "codex"})
        |> with_rows(1)
        |> name_rows(["user"])
        |> with_params(%{"cli" => "claude"})

      raw = %{"headers_password" => %{"new" => %{"1" => "u-1"}}}
      assert ProviderAccountForm.header_attrs(claude, raw) == nil
      refute Map.has_key?(ProviderAccountForm.attrs(claude, raw), "headers")
    end

    test "an edit: new values and rows set, marks delete, the rest untouched" do
      form =
        ProviderAccountForm.edit(1, codex_view(["Ocp-Apim-Subscription-Key", "user", "x-a"]))
        |> ProviderAccountForm.toggle_delete("Ocp-Apim-Subscription-Key")
        |> with_rows(1)
        |> name_rows(["x-new"])

      raw = %{
        "headers_password" => %{
          "existing" => %{"0" => "ignored-because-marked", "1" => "u-2", "2" => ""},
          "new" => %{"1" => "n-1"}
        }
      }

      assert ProviderAccountForm.header_attrs(form, raw) == %{
               "set" => %{"user" => "u-2", "x-new" => "n-1"},
               "delete" => ["Ocp-Apim-Subscription-Key"]
             }
    end

    test "an edit without header changes submits none" do
      form = ProviderAccountForm.edit(1, codex_view(["user"]))
      raw = %{"headers_password" => %{"existing" => %{"0" => ""}}}
      assert ProviderAccountForm.header_attrs(form, raw) == nil
      refute Map.has_key?(ProviderAccountForm.attrs(form, raw), "headers")
    end

    test "a deletion mark can be taken back; unknown names are ignored" do
      form = ProviderAccountForm.edit(1, codex_view(["user"]))
      marked = ProviderAccountForm.toggle_delete(form, "user")
      assert marked.deleted == ["user"]
      assert ProviderAccountForm.toggle_delete(marked, "user").deleted == []
      assert ProviderAccountForm.toggle_delete(form, "other") == form
    end

    test "at most 8: stored not marked plus new rows" do
      form = ProviderAccountForm.edit(1, codex_view(Enum.map(1..6, &"x-h#{&1}"))) |> with_rows(2)
      assert ProviderAccountForm.header_count(form) == 8
      refute ProviderAccountForm.can_add_header?(form)
      assert ProviderAccountForm.add_row(form) == form

      form = ProviderAccountForm.toggle_delete(form, "x-h1")
      assert ProviderAccountForm.can_add_header?(form)
      assert length(ProviderAccountForm.add_row(form).rows) == 3
    end
  end

  describe "change/3 with headers" do
    test "row names are kept, values never", ctx do
      form =
        ProviderAccountForm.new(1)
        |> with_params(%{"cli" => "codex"})
        |> ProviderAccountForm.add_row()
        |> ProviderAccountForm.change(ctx.scope, %{
          "account" => %{
            "cli" => "codex",
            "new" => %{"1" => %{"name" => "user"}},
            "headers_password" => %{
              "new" => %{"1" => "hv-sentinel-1"},
              "existing" => %{"0" => "hv-sentinel-2"}
            }
          }
        })

      assert [%{name: "user"}] = form.rows
      refute inspect(form) =~ "hv-sentinel"
    end
  end
end
