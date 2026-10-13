defmodule HelmsmanWeb.AgentFormTest do
  @moduledoc """
  add-agent-conversation-ui D7: the attrs of the draft forms (`:draft_new`,
  `:draft_edit`) and the three-way merge after a `stale` save.
  """
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias HelmsmanWeb.AgentForm

  setup do
    alice = user_fixture()
    ws = workspace_fixture(alice)
    %{scope: workspace_scope_fixture(alice, ws)}
  end

  @entry %{
    "name" => "fe-dev",
    "provider" => "claude",
    "description" => "前端",
    "runtime_id" => 7,
    "provider_account_id" => nil,
    "model" => "sonnet",
    "effort" => "high",
    "instructions" => "做前端。",
    "capabilities" => [],
    "access" => "owner_only",
    "max_concurrency" => 2,
    "timeout_minutes" => 120,
    "idle_timeout_minutes" => 20,
    "updated_by" => "ai"
  }

  defp edit(scope, params) do
    form = AgentForm.draft_edit(scope, 1, @entry)
    {_form, attrs} = AgentForm.draft_submit(form, %{"agent" => params})
    attrs
  end

  describe "draft_attrs/1" do
    test ":draft_edit: only the changed fields, with the name", %{scope: scope} do
      assert edit(scope, %{"effort" => "medium", "description" => "前端"}) ==
               %{"name" => "fe-dev", "effort" => "medium"}

      assert edit(scope, %{}) == %{"name" => "fe-dev"}
    end

    test "a rename carries previous_name", %{scope: scope} do
      assert edit(scope, %{"name" => " web-dev "}) ==
               %{"name" => "web-dev", "previous_name" => "fe-dev"}
    end

    test "clearing the runtime, model or effort submits nil", %{scope: scope} do
      assert edit(scope, %{"runtime_id" => "", "model" => "", "effort" => ""}) == %{
               "name" => "fe-dev",
               "runtime_id" => nil,
               "model" => nil,
               "effort" => nil
             }
    end

    test "never secrets, CLI arguments or members", %{scope: scope} do
      attrs =
        edit(scope, %{
          "env_add" => %{"1" => %{"name" => "FOO", "value" => "x"}},
          "env_new" => %{"BAR" => "y"},
          "mcp" => ~s({"a":{}}),
          "custom_args" => "--x",
          "access_member_ids" => ["1"],
          "access" => "workspace",
          "capabilities" => ["", "create_tasks"]
        })

      assert attrs == %{
               "name" => "fe-dev",
               "access" => "workspace",
               "capabilities" => ["create_tasks"]
             }
    end

    test ":draft_new: every draft field and the name", %{scope: scope} do
      form = AgentForm.draft_new(scope, 1)

      {_form, attrs} =
        AgentForm.draft_submit(form, %{
          "agent" => %{
            "name" => "qa",
            "provider" => "claude",
            "instructions" => "测",
            "custom_args" => "--x"
          }
        })

      assert attrs["name"] == "qa"
      assert attrs["runtime_id"] == nil
      assert attrs["max_concurrency"] == 2

      assert Map.keys(attrs) |> Enum.sort() ==
               Enum.sort(~w(name description provider runtime_id provider_account_id model effort
                            instructions access capabilities max_concurrency timeout_minutes
                            idle_timeout_minutes))
    end

    test "moving a bound agent to a CLI without accounts unbinds it", %{scope: scope} do
      form =
        AgentForm.draft_edit(scope, 1, %{
          @entry
          | "provider_account_id" => 3,
            "provider" => "claude"
        })

      {_form, attrs} = AgentForm.draft_submit(form, %{"agent" => %{"provider" => "gemini"}})
      assert attrs["provider_account_id"] == nil
      assert Map.has_key?(attrs, "provider_account_id")
    end
  end

  describe "rebase/3" do
    test "untouched fields take the fresh values, changed ones stay; the base moves", %{
      scope: scope
    } do
      form = AgentForm.draft_edit(scope, 1, @entry)
      {form, _} = AgentForm.draft_submit(form, %{"agent" => %{"effort" => "medium"}})
      fresh = %{@entry | "description" => "别处改的", "effort" => "low"}

      form = AgentForm.rebase(form, scope, fresh)
      assert form.notice == :draft_stale
      assert form.params["effort"] == "medium"
      assert form.params["description"] == "别处改的"
      assert AgentForm.draft_attrs(form) == %{"name" => "fe-dev", "effort" => "medium"}
    end

    test "a removed agent turns the form into an addition", %{scope: scope} do
      form = AgentForm.draft_edit(scope, 1, @entry) |> AgentForm.rebase(scope, nil)
      assert form.mode == :draft_new
      assert form.notice == :draft_removed
      assert AgentForm.draft_attrs(form)["name"] == "fe-dev"
    end
  end
end
